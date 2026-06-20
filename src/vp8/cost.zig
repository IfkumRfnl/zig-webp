//! VP8 boolean-coder bit costs for encoder rate estimation.
//!
//! `entropy_cost[p]` is the cost, in 1/256-bit units, of coding a boolean whose
//! probability-of-zero is `p/256` when the coded bit is 0; coding a 1 costs
//! `entropy_cost[255 - p]`. The table is transcribed value-for-value from
//! `references/libwebp` (`src/dsp/cost.c`, `VP8EntropyCost`); index 128 is 256,
//! i.e. a fair (p = 0.5) bit costs exactly one bit, which fixes the unit.
//!
//! These are *ideal* entropy costs (sum of -log2 p), not the arithmetic coder's
//! emitted byte count, so they let the encoder rank candidate codings by bits
//! without actually emitting them. The rate term of the rate-distortion mode
//! decision is built from these (see `tokens.blockCost`).

const std = @import("std");

/// One bit, in the 1/256-bit fixed-point unit the costs use.
pub const bit_cost = 256;

/// RFC/libwebp `VP8EntropyCost`: cost in 1/256-bit units of coding a 0 at each
/// probability-of-zero value.
pub const entropy_cost = [256]u16{
    1792, 1792, 1792, 1536, 1536, 1408, 1366, 1280, 1280, 1216, 1178, 1152,
    1110, 1076, 1061, 1024, 1024, 992,  968,  951,  939,  911,  896,  878,
    871,  854,  838,  820,  811,  794,  786,  768,  768,  752,  740,  732,
    720,  709,  704,  690,  683,  672,  666,  655,  647,  640,  631,  622,
    615,  607,  598,  592,  586,  576,  572,  564,  559,  555,  547,  541,
    534,  528,  522,  512,  512,  504,  500,  494,  488,  483,  477,  473,
    467,  461,  458,  452,  448,  443,  438,  434,  427,  424,  419,  415,
    410,  406,  403,  399,  394,  390,  384,  384,  377,  374,  370,  366,
    362,  359,  355,  351,  347,  342,  342,  336,  333,  330,  326,  323,
    320,  316,  312,  308,  305,  302,  299,  296,  293,  288,  287,  283,
    280,  277,  274,  272,  268,  266,  262,  256,  256,  256,  251,  248,
    245,  242,  240,  237,  234,  232,  228,  226,  223,  221,  218,  216,
    214,  211,  208,  205,  203,  201,  198,  196,  192,  191,  188,  187,
    183,  181,  179,  176,  175,  171,  171,  168,  165,  163,  160,  159,
    156,  154,  152,  150,  148,  146,  144,  142,  139,  138,  135,  133,
    131,  128,  128,  125,  123,  121,  119,  117,  115,  113,  111,  110,
    107,  105,  103,  102,  100,  98,   96,   94,   92,   91,   89,   86,
    86,   83,   82,   80,   77,   76,   74,   73,   71,   69,   67,   66,
    64,   63,   61,   59,   57,   55,   54,   52,   51,   49,   47,   46,
    44,   43,   41,   40,   38,   36,   35,   33,   32,   30,   29,   27,
    25,   24,   22,   21,   19,   18,   16,   15,   13,   12,   10,   9,
    7,    6,    4,    3,
};

comptime {
    std.debug.assert(entropy_cost[128] == bit_cost); // a fair bit is one bit
    std.debug.assert(entropy_cost.len == 256);
}

/// Cost in 1/256-bit units of coding `bit` with probability-of-zero `proba`.
pub fn boolCost(proba: u8, bit: u1) u32 {
    return entropy_cost[if (bit == 1) 255 - @as(usize, proba) else proba];
}

test "boolCost matches the entropy table both ways" {
    // A fair coin costs one bit either way.
    try std.testing.expectEqual(@as(u32, bit_cost), boolCost(128, 0));
    try std.testing.expectEqual(@as(u32, entropy_cost[127]), boolCost(128, 1));

    // A near-certain 0 is cheap to code as 0, dear to code as 1.
    try std.testing.expect(boolCost(254, 0) < boolCost(128, 0));
    try std.testing.expect(boolCost(254, 1) > boolCost(128, 1));
    // Symmetry of the indexing: coding 1 at proba p equals coding 0 at 255-p.
    try std.testing.expectEqual(boolCost(200, 1), boolCost(@as(u8, 255 - 200), 0));
}
