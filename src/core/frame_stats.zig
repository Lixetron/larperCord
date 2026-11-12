//! Estatísticas baratas de um quadro RGBA: "mudou?" e "quanto mudou?".
//! A amostra 16×16 de luma cabe num punhado de bytes e responde às duas
//! perguntas sem olhar o quadro inteiro — é o que separa "60 quadros novos por
//! segundo" de "60 quadros quase iguais, com 5 de movimento por segundo".

const std = @import("std");

pub const grid_n: u32 = 16;
pub const grid_len: usize = grid_n * grid_n;

/// Amostra 16×16 de luma (0..255) do quadro RGBA `px` (w × h).
pub fn sample(px: []const u8, w: u32, h: u32, grid: *[grid_len]u8) void {
    var yy: u32 = 0;
    while (yy < grid_n) : (yy += 1) {
        const y = (h * yy) / grid_n;
        var xx: u32 = 0;
        while (xx < grid_n) : (xx += 1) {
            const x = (w * xx) / grid_n;
            const idx: usize = @intCast((y * w + x) * 4);
            if (idx + 3 >= px.len) {
                grid[yy * grid_n + xx] = 0;
                continue;
            }
            const r: u32 = px[idx];
            const g: u32 = px[idx + 1];
            const b: u32 = px[idx + 2];
            grid[yy * grid_n + xx] = @intCast((r * 77 + g * 150 + b * 29) >> 8);
        }
    }
}

/// FNV-1a da amostra: igual ⇒ o quadro não mudou.
pub fn hash(grid: *const [grid_len]u8) u64 {
    var hsh: u64 = 1469598103934665603;
    for (grid) |v| hsh = (hsh ^ v) *% 1099511628211;
    return hsh;
}

/// Diferença média de luma (0..255) entre duas amostras.
pub fn diff(a: *const [grid_len]u8, b: *const [grid_len]u8) u32 {
    var sum: u32 = 0;
    for (a, b) |x, y| sum += if (x > y) x - y else y - x;
    return sum / @as(u32, @intCast(grid_len));
}

test "amostra 16×16: quadro igual não move, faixa branca move" {
    var ga: [grid_len]u8 = undefined;
    var gb: [grid_len]u8 = undefined;
    // 16×16 RGBA: um pixel por amostra, sem reduzir.
    var px: [16 * 16 * 4]u8 = @splat(0);
    sample(&px, 16, 16, &ga);
    try std.testing.expectEqual(@as(u32, 0), diff(&ga, &ga));
    try std.testing.expectEqual(hash(&ga), hash(&ga));
    // Uma coluna branca muda o hash e a diferença média.
    for (0..16) |y| {
        const i = (y * 16 + 5) * 4;
        px[i] = 255;
        px[i + 1] = 255;
        px[i + 2] = 255;
    }
    sample(&px, 16, 16, &gb);
    try std.testing.expect(hash(&ga) != hash(&gb));
    try std.testing.expect(diff(&ga, &gb) > 0);
    // Diferença simétrica e limitada ao que mudou (16 de 256 amostras).
    try std.testing.expectEqual(diff(&ga, &gb), diff(&gb, &ga));
    try std.testing.expect(diff(&ga, &gb) <= 16);
}
