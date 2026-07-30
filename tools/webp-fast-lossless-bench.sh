#!/usr/bin/env bash
set -euo pipefail
usage() { cat <<'HELP'
usage: tools/webp-fast-lossless-bench.sh --output PATH [--zig-method 0..6]

Direct-API Plan 030 benchmark. It prepares identical RGBA before timing, then
measures Zig encodeLossless, libwebp lossless preset 0, and libwebp preset 6.
The stable command selects Zig method 0 (currently identical to the default
lossless path); --zig-method 4 selects the existing default/full control.

Each effort uses 3 warmups and 15 median samples. Tiny inputs are batched up to
roughly 262144 pixels (maximum 256 encodes). Timing includes RGBA/ARGB
gathering, encoder work, output allocation, and cleanup, but excludes source I/O.
libwebp uses exact=1 and thread_level=0. Codec and dwebp pixel-exact validation is fatal;
performance and size gates are diagnostics in the TSV. All generated C, raw,
PAM, and WebP artifacts remain under .zig-cache/webp-fast-lossless-bench.
HELP
}
output=; zig_method=0
while (($#)); do
  case "$1" in
    --output)
      (($# >= 2)) || { echo "benchmark: --output requires a value" >&2; exit 2; }
      output=$2; shift 2
      ;;
    --zig-method)
      (($# >= 2)) || { echo "benchmark: --zig-method requires a value" >&2; exit 2; }
      zig_method=$2; shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "benchmark: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$output" ]] || { echo "benchmark: --output PATH is required" >&2; exit 2; }
[[ "$zig_method" =~ ^[0-6]$ ]] || { echo "benchmark: --zig-method must be 0..6" >&2; exit 2; }
command -v zig >/dev/null || { echo "benchmark: missing required Zig compiler" >&2; exit 1; }
command -v cc >/dev/null || { echo "benchmark: missing required C compiler 'cc'" >&2; exit 1; }
command -v dwebp >/dev/null || { echo "benchmark: missing required libwebp tool 'dwebp'" >&2; exit 1; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$root"
manifest=testdata/ui/corpus.tsv; work=.zig-cache/webp-fast-lossless-bench
mkdir -p "$work"/{raw,out,pam,c}
adapter=$work/c/libwebp_adapter
cat >"$adapter.c" <<'C'
#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <webp/decode.h>
#include <webp/encode.h>
#define WARMUPS 3u
#define SAMPLES 15u
#define BATCH_PIXELS 262144u
#define BATCH_MAX 256u
typedef struct { uint8_t *storage, *pixels; uint32_t width, height; size_t bytes; } Raw;
static void die(const char *s) { fprintf(stderr,"libwebp adapter: %s\n",s); exit(1); }
static uint32_t le32(const uint8_t *p) { return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static Raw read_raw(const char *path) {
  FILE *f=fopen(path,"rb"); if(!f) die("cannot open RGBA input");
  if(fseek(f,0,SEEK_END)) die("cannot seek RGBA input");
  long n=ftell(f);
  if(n<12||fseek(f,0,SEEK_SET)) die("invalid RGBA input");
  uint8_t *s=malloc((size_t)n); if(!s) die("out of memory");
  if(fread(s,1,(size_t)n,f)!=(size_t)n||fclose(f)) die("cannot read RGBA input");
  uint32_t w=le32(s+4),h=le32(s+8); uint64_t bytes=(uint64_t)w*h*4;
  if(memcmp(s,"RGBA",4)||!w||!h||bytes!=(uint64_t)n-12) die("invalid RGBA header");
  return (Raw){s,s+12,w,h,(size_t)bytes};
}
static uint64_t now_ns(void) { struct timespec t; if(clock_gettime(CLOCK_MONOTONIC,&t)) die("clock failure"); return (uint64_t)t.tv_sec*1000000000u+t.tv_nsec; }
static int cmp(const void *a,const void *b) { uint64_t x=*(const uint64_t*)a,y=*(const uint64_t*)b; return (x>y)-(x<y); }
static WebPMemoryWriter encode(const Raw *r,int preset) {
  WebPConfig c; WebPPicture p; WebPMemoryWriter w;
  if(!WebPConfigInit(&c)) die("libwebp encoder ABI mismatch");
  if(!WebPConfigLosslessPreset(&c,preset)) die("WebPConfigLosslessPreset failed");
  c.exact=1; c.thread_level=0; if(!WebPValidateConfig(&c)) die("invalid config");
  if(!WebPPictureInit(&p)) die("libwebp ABI mismatch");
  p.use_argb=1; p.width=(int)r->width; p.height=(int)r->height;
  WebPMemoryWriterInit(&w); p.writer=WebPMemoryWrite; p.custom_ptr=&w;
  if(!WebPPictureImportRGBA(&p,r->pixels,(int)r->width*4)) { WebPPictureFree(&p); die("RGBA import failed"); }
  if(!WebPEncode(&c,&p)) { WebPPictureFree(&p); WebPMemoryWriterClear(&w); die("encode failed"); }
  WebPPictureFree(&p); return w;
}
static void batch(const Raw *r,int preset,uint32_t n) { for(uint32_t i=0;i<n;i++){ WebPMemoryWriter w=encode(r,preset); WebPMemoryWriterClear(&w); } }
static uint32_t colors(const Raw *r) {
  uint32_t seen[256],n=0;
  for(size_t o=0;o<r->bytes;o+=4){ uint32_t c=le32(r->pixels+o),i=0; while(i<n&&seen[i]!=c)i++; if(i==n){if(n==256)return 257;seen[n++]=c;} }
  return n;
}
static int alpha(const Raw *r) { for(size_t o=3;o<r->bytes;o+=4)if(r->pixels[o]!=255)return 1; return 0; }
static void save(const char *path,const uint8_t *p,size_t n) { FILE *f=fopen(path,"wb"); if(!f||fwrite(p,1,n,f)!=n||fclose(f))die("cannot write output"); }
static void bench(const Raw *r,const char *class,const char *source,const char *prov,const char *path,int preset) {
  uint64_t pixels=(uint64_t)r->width*r->height; uint32_t b=(uint32_t)(BATCH_PIXELS/pixels); if(b<1)b=1;if(b>BATCH_MAX)b=BATCH_MAX;
  for(uint32_t i=0;i<WARMUPS;i++) batch(r,preset,b);
  uint64_t s[SAMPLES];
  for(uint32_t i=0;i<SAMPLES;i++){uint64_t start=now_ns();batch(r,preset,b);s[i]=(now_ns()-start)/b;}
  qsort(s,SAMPLES,sizeof(*s),cmp); uint64_t median=s[SAMPLES/2]; WebPMemoryWriter out=encode(r,preset);
  uint8_t *decoded=WebPDecodeRGBA(out.mem,out.size,NULL,NULL);
  if(!decoded||memcmp(decoded,r->pixels,r->bytes)) die("pixel-exact round-trip failed");
  WebPFree(decoded); save(path,out.mem,out.size);
  uint32_t count=colors(r); double mpps=(double)pixels*1000.0/(double)median;
  printf("file\t%s\t%s\t%s\tlibwebp\tpreset-%d\t%u\t%u\t%" PRIu64 "\t%u\t%s\t%s\t%u\t%u\t%" PRIu64 "\t%.6f\t%zu\tyes\tyes\n",class,source,prov,preset,r->width,r->height,pixels,count,count<=256?"yes":"no",alpha(r)?"yes":"no",SAMPLES,b,median,mpps,out.size);
  WebPMemoryWriterClear(&out);
}
int main(int argc,char **argv) {
  if(argc!=7)die("usage: ADAPTER RAW CLASS SOURCE PROVENANCE PRESET0.webp PRESET6.webp");
  Raw r=read_raw(argv[1]); bench(&r,argv[2],argv[3],argv[4],argv[5],0); bench(&r,argv[2],argv[3],argv[4],argv[6],6); free(r.storage); return 0;
}
C
if cc -O3 -std=c11 -Wall -Wextra -Werror "$adapter.c" -lwebp -o "$adapter" 2>/dev/null; then
  :
elif cc -O3 -std=c11 -Wall -Wextra -Werror -Ireferences/libwebp/src \
    "$adapter.c" -l:libwebp.so.7 -o "$adapter"; then
  :
else
  echo "benchmark: system libwebp and optional references/libwebp clone compile/link attempts failed" >&2
  echo "benchmark: install libwebp development files or clone references/libwebp; see references/README.MD" >&2
  exit 1
fi
zig_rows=$work/zig.tsv; c_rows=$work/c.tsv; : >"$c_rows"
zig build -Doptimize=ReleaseFast fast-lossless-bench-tool -- prepare-bench "$manifest" "$work" "$zig_rows" "$zig_method"
count=0
while IFS=$'\t' read -r id class kind source provenance license; do
  [[ -n "$id" && ${id:0:1} != '#' && $id != id ]] || continue; ((count+=1))
  "$adapter" "$work/raw/$id.rgba" "$class" "$id" "$provenance" "$work/out/$id.c-preset0.webp" "$work/out/$id.c-preset6.webp" >>"$c_rows"
done <"$manifest"
while IFS=$'\t' read -r id class kind source provenance license; do
  [[ -n "$id" && ${id:0:1} != '#' && $id != id ]] || continue
  for suffix in zig c-preset0 c-preset6; do
    pam=$work/pam/$id.$suffix.pam
    dwebp "$work/out/$id.$suffix.webp" -pam -o "$pam" >/dev/null 2>&1 || { echo "benchmark: dwebp rejected $id.$suffix" >&2; exit 1; }
    zig build -Doptimize=ReleaseFast fast-lossless-bench-tool -- validate "$work/raw/$id.rgba" "$pam"
  done
done <"$manifest"
rows=$work/rows.tsv; cat "$zig_rows" "$c_rows" >"$rows"
awk -F'\t' -v want="$((count*3))" '
  $1=="file" {
    n++; per_source[$3]++;
    key=$3 SUBSEP $5 SUBSEP $6;
    if (++seen[key] != 1 || $18!="yes" || $19!="yes") bad++;
  }
  END {
    for (source in per_source) if (per_source[source] != 3) bad++;
    if (n!=want || bad) {
      printf "benchmark: incomplete/invalid rows (%d/%d, bad=%d)\n",n,want,bad >"/dev/stderr";
      exit 1;
    }
  }
' "$rows"
mkdir -p "$(dirname "$output")"; tmp=$work/report.tmp
{
  echo '# Plan 030 direct-API matched-effort VP8L benchmark.'
  echo '# RGBA prepared before timing; encode preparation/allocation/cleanup included; source I/O excluded.'
  echo '# 3 warmups; 15 samples; median ns/encode; tiny inputs batched; exact single-threaded libwebp.'
  echo "# corpus=$manifest zig_method=$zig_method primary=opaque-ui,alpha-ui secondary=palette-miss"
  printf 'row_type\tclass\tsource\tprovenance\timplementation\teffort\twidth\theight\tpixels\tcolor_count\tpalette_hit\talpha\tsamples\tbatch\tmedian_ns\tmpps\tbytes\troundtrip\tvalidity\n'
  cat "$rows"
  awk -F'\t' '$1=="file"{k=$2 SUBSEP $5 SUBSEP $6;n[k]++;ns[k]+=$15;bytes[k]+=$17;logs[k]+=log($15)}END{print "# summary_fields\tclass\timplementation\teffort\trows\tgeomean_ns\tsummed_ns\taggregate_bytes";for(k in n){split(k,p,SUBSEP);printf "# summary\t%s\t%s\t%s\t%d\t%.3f\t%.0f\t%.0f\n",p[1],p[2],p[3],n[k],exp(logs[k]/n[k]),ns[k],bytes[k]}}' "$rows"
  awk -F'\t' '
    NR==FNR {
      if ($2=="opaque-ui" || $2=="alpha-ui") {
        if (!($1 in expected_primary)) expected_primary_count++;
        expected_primary[$1]=1;
      }
      next;
    }
    $1=="file" && ($3 in expected_primary) {
      if ($5=="zig-current") {
        if (($15+0)>0 && ($17+0)>0) {
          zt[$3]=$15; zb[$3]=$17; zig_complete[$3]=1;
        }
      } else if ($6=="preset-0") {
        if (($15+0)>0 && ($17+0)>0) {
          ft[$3]=$15; fb[$3]=$17; preset0_complete[$3]=1;
        }
      }
    }
    END {
      for (id in expected_primary) {
        if (!(id in zig_complete) || !(id in preset0_complete)) continue;
        ratio=zt[id]/ft[id]; log_ratio+=log(ratio); primary_count++;
        if (substr(id,1,5)=="real-") {
          real_count++;
          real_wins+=(ratio<1);
        }
        zig_bytes+=zb[id]; preset0_bytes+=fb[id];
        size_ratio=zb[id]/fb[id];
        if (size_ratio>max_size_ratio) max_size_ratio=size_ratio;
      }
      complete=(expected_primary_count>0 && primary_count==expected_primary_count);
      geomean=(primary_count>0) ? exp(log_ratio/primary_count) : 0;
      real_win_fraction=(real_count>0) ? real_wins/real_count : 0;
      aggregate_size_ratio=(preset0_bytes>0) ? zig_bytes/preset0_bytes : 0;
      printf "# gate\tprimary_geomean_time_ratio\t%.6f\t<=0.90\t%s\n",geomean,(complete && geomean <= 0.90) ? "PASS" : "FAIL";
      printf "# gate\tprimary_real_asset_row_win_fraction\t%.6f\t>=0.70\t%s\treal_rows=%d\n",real_win_fraction,(complete && real_count>0 && real_win_fraction >= 0.70) ? "PASS" : "FAIL",real_count;
      printf "# gate\tprimary_aggregate_size_ratio_vs_preset0\t%.6f\t<=1.15\t%s\n",aggregate_size_ratio,(complete && preset0_bytes>0 && aggregate_size_ratio <= 1.15) ? "PASS" : "FAIL";
      printf "# gate\tprimary_max_size_ratio_vs_preset0\t%.6f\t<=1.30\t%s\n",max_size_ratio,(complete && max_size_ratio <= 1.30) ? "PASS" : "FAIL";
      printf "# gate\tcomplete_valid_primary_sources\t%d\trequired-all\t%s\n",primary_count,complete ? "PASS" : "FAIL";
    }
  ' "$manifest" "$rows"
} >"$tmp"
mv "$tmp" "$output"
echo "benchmark: wrote $((count*3)) valid rows to $output" >&2
