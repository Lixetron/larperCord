//! Vídeo do Discord: o RTP que chega, o H.264 que sai dele.
//!
//! O transporte é o mesmo da voz (UDP, XChaCha20-Poly1305 "rtpsize"), mas o
//! payload é H.264 empacotado como no WebRTC: um NAL por pacote, STAP-A para
//! NALs pequenos juntos, ou FU-A quando o NAL não cabe num pacote. O bit de
//! marcação fecha o quadro; o timestamp de 90 kHz diz a que quadro cada
//! pacote pertence.
//!
//! Este módulo é só o que dá para testar sem rede: o cabeçalho RTP, a
//! remontagem dos NALs e o pedido de quadro-chave (RTCP PLI). Quem decifra e
//! quem decodifica está em net/voz_video.zig.
const std = @import("std");

/// Um quadro de 1080p em H.264 fica bem abaixo disto; o teto evita que um
/// fluxo quebrado cresça sem fim.
pub const max_frame_bytes: usize = 8 << 20;

/// O que o cabeçalho (em claro) diz. `aad_len` são os bytes autenticados mas
/// não cifrados; `ext_len` são as extensões, que vêm cifradas junto com o
/// payload e saem depois de decifrar.
pub const Header = struct {
    marker: bool,
    payload_type: u8,
    seq: u16,
    ts: u32,
    ssrc: u32,
    aad_len: usize,
    ext_len: usize,
    padding: bool,
};

/// Lê o cabeçalho RTP. `null` = não é RTP versão 2 ou está truncado.
pub fn parseHeader(buf: []const u8) ?Header {
    if (buf.len < 12) return null;
    if (buf[0] >> 6 != 2) return null;
    const csrc = @as(usize, buf[0] & 0x0f);
    const has_ext = buf[0] & 0x10 != 0;
    var off = 12 + csrc * 4;
    if (off > buf.len) return null;
    var ext_len: usize = 0;
    if (has_ext) {
        if (off + 4 > buf.len) return null;
        const words = std.mem.readInt(u16, buf[off + 2 ..][0..2], .big);
        off += 4;
        ext_len = @as(usize, words) * 4;
    }
    return .{
        .marker = buf[1] & 0x80 != 0,
        .payload_type = buf[1] & 0x7f,
        .seq = std.mem.readInt(u16, buf[2..4], .big),
        .ts = std.mem.readInt(u32, buf[4..8], .big),
        .ssrc = std.mem.readInt(u32, buf[8..12], .big),
        .aad_len = off,
        .ext_len = ext_len,
        .padding = buf[0] & 0x20 != 0,
    };
}

/// RTCP divide o mesmo socket; o segundo byte é 200–207 e não um payload type.
pub fn isRtcp(buf: []const u8) bool {
    return buf.len >= 8 and buf[0] >> 6 == 2 and buf[1] >= 200 and buf[1] <= 207;
}

/// PLI (Picture Loss Indication): pede ao remetente um quadro-chave, para quem
/// acabou de começar a assistir não esperar o próximo intervalo. O cabeçalho
/// vai em claro; só o SSRC da mídia é cifrado (o chamador cifra).
pub fn writePli(buf: []u8, sender: u32, media: u32) ?[]const u8 {
    if (buf.len < 12) return null;
    buf[0] = 0x81; // V=2, FMT=1 (PLI)
    buf[1] = 206; // PSFB
    std.mem.writeInt(u16, buf[2..4], 2, .big); // 12 bytes: (12 / 4) - 1
    std.mem.writeInt(u32, buf[4..8], sender, .big);
    std.mem.writeInt(u32, buf[8..12], media, .big);
    return buf[0..12];
}

/// O número de sequência da extensão transport-cc (id 5) no corpo da extensão
/// RTP de um byte (0xBEDE), já decifrado.
pub fn transportSeq(ext: []const u8) ?u16 {
    var i: usize = 0;
    while (i + 1 <= ext.len) {
        const b = ext[i];
        if (b == 0) {
            // Preenchimento até o próximo múltiplo de 4 bytes.
            i += 1;
            continue;
        }
        const id = b >> 4;
        const len: usize = @as(usize, b & 0x0f) + 1;
        i += 1;
        if (i + len > ext.len) return null;
        if (id == 5 and len >= 2) return std.mem.readInt(u16, ext[i..][0..2], .big);
        i += len;
    }
    return null;
}

/// RTCP Receiver Report (PT 201) com um bloco: 32 bytes. `jitter` em unidades
/// de 1/90000 s; `lsr`/`dlsr` vêm do último Sender Report do SFU (RTT).
pub fn writeRr(buf: []u8, sender: u32, media: u32, ext_seq: u32, jitter: u32, lsr: u32, dlsr: u32) ?[]const u8 {
    if (buf.len < 32) return null;
    @memset(buf[0..32], 0);
    buf[0] = 0x81; // V=2, RC=1
    buf[1] = 201; // Receiver Report
    std.mem.writeInt(u16, buf[2..4], 7, .big); // (32 / 4) - 1
    std.mem.writeInt(u32, buf[4..8], sender, .big);
    std.mem.writeInt(u32, buf[8..12], media, .big);
    // fraction lost (0) e cumulative lost (0) em 12..16
    std.mem.writeInt(u32, buf[16..20], ext_seq, .big);
    std.mem.writeInt(u32, buf[20..24], jitter, .big);
    std.mem.writeInt(u32, buf[24..28], lsr, .big);
    std.mem.writeInt(u32, buf[28..32], dlsr, .big);
    return buf[0..32];
}

/// RTCP REMB (PT 206, FMT 15): "aqui cabe N bits/s". É um dos sinais que o
/// remetente usa para soltar mais bitrate. Um SSRC, 24 bytes.
pub fn writeRemb(buf: []u8, sender: u32, media: u32, bitrate_bps: u32) ?[]const u8 {
    if (buf.len < 24) return null;
    @memset(buf[0..24], 0);
    buf[0] = 0x8f; // V=2, FMT=15
    buf[1] = 206; // PSFB
    std.mem.writeInt(u16, buf[2..4], 5, .big); // (24 / 4) - 1
    std.mem.writeInt(u32, buf[4..8], sender, .big);
    // 8..12: campo "unused", zero (o SSRC da mídia vai só na lista do fim).
    @memcpy(buf[12..16], "REMB");
    buf[16] = 1; // um SSRC
    // Bitrate = mantissa × 2^exp, mantissa em 18 bits.
    var exp: u6 = 0;
    var mant: u32 = bitrate_bps;
    while (mant >= (1 << 18) and exp < 46) : (exp += 1) mant >>= 1;
    buf[17] = (@as(u8, exp) << 2) | @as(u8, @intCast((mant >> 16) & 0x03));
    buf[18] = @intCast((mant >> 8) & 0xff);
    buf[19] = @intCast(mant & 0xff);
    std.mem.writeInt(u32, buf[20..24], media, .big);
    return buf[0..24];
}

/// Uma chegada de pacote para o feedback transport-cc.
pub const CcSample = struct { seq: u16, us: u64 };

/// RTCP Transport Feedback (PT 205, FMT 15) de um intervalo: sequência base,
/// contagem, chunks e deltas de chegada. Pacotes que não vieram entram como
/// "não recebido". Devolve o RTCP em claro (o chamador cifra do byte 8 em
/// diante, como todo RTCP "rtpsize").
pub fn writeTransportCc(buf: []u8, sender: u32, media: u32, samples: []const CcSample, pkt: u8) ?[]const u8 {
    if (samples.len == 0 or buf.len < 8 + 12 + 192 * 2 + 192 * 2 + 4) return null;

    // Todas as amostras ficam a menos de meio espaço de sequência da primeira,
    // então a diferença de 16 bits dá a posição relativa (com sinal). O viés
    // mantém tudo positivo para comparar mínimo e máximo.
    const bias: i64 = 1 << 16;
    const base_i: i64 = samples[0].seq;
    var lo: i64 = bias + base_i;
    var hi: i64 = lo;
    for (samples) |s| {
        const ext = bias + base_i + @as(i64, @as(i16, @bitCast(s.seq -% samples[0].seq)));
        if (ext < lo) lo = ext;
        if (ext > hi) hi = ext;
    }
    var start = lo;
    if (hi - start >= 180) start = hi - 179;
    const count: u32 = @intCast(hi - start + 1);

    // Referência: chegada do primeiro pacote recebido da faixa.
    var ref_us: u64 = 0;
    for (samples) |s| {
        const ext = bias + base_i + @as(i64, @as(i16, @bitCast(s.seq -% samples[0].seq)));
        if (ext >= start) {
            ref_us = s.us;
            break;
        }
    }
    if (ref_us == 0) return null;
    const ref_time: u32 = @intCast((ref_us / 64000) & 0xFFFFFF);
    var prev_us: i64 = @intCast(@as(u64, ref_time) * 64000);

    var chunks: [184]u16 = undefined;
    var deltas: [368]u8 = undefined;
    var ci: usize = 0;
    var nd: usize = 0;
    var ext = start;
    while (ext <= hi) : (ext += 1) {
        var arrival: u64 = 0;
        var found = false;
        for (samples) |s| {
            if (bias + base_i + @as(i64, @as(i16, @bitCast(s.seq -% samples[0].seq))) == ext) {
                arrival = s.us;
                found = true;
                break;
            }
        }
        if (!found) {
            chunks[ci] = 0x0000; // não recebido
            ci += 1;
            continue;
        }
        const delta: i64 = @as(i64, @intCast(arrival)) - prev_us;
        if (delta < 0 or delta > 63750) {
            const q: i64 = std.math.clamp(@divTrunc(delta, 250), -32768, 32767);
            const v: u16 = @bitCast(@as(i16, @intCast(q)));
            chunks[ci] = 0x4000; // recebido, delta grande ou negativo
            ci += 1;
            deltas[nd] = @intCast(v >> 8);
            deltas[nd + 1] = @intCast(v & 0xFF);
            nd += 2;
        } else {
            chunks[ci] = 0x2000; // recebido, delta pequeno
            ci += 1;
            deltas[nd] = @intCast(@divTrunc(delta, 250));
            nd += 1;
        }
        prev_us = @intCast(arrival);
    }

    var total: usize = 8 + 12 + ci * 2 + nd;
    total += (4 - (total % 4)) % 4;
    if (total > buf.len) return null;

    @memset(buf[0..total], 0);
    buf[0] = 0x8f; // V=2, FMT=15
    buf[1] = 205; // RTPFB
    std.mem.writeInt(u16, buf[2..4], @intCast(total / 4 - 1), .big);
    std.mem.writeInt(u32, buf[4..8], sender, .big);
    std.mem.writeInt(u32, buf[8..12], media, .big);
    std.mem.writeInt(u16, buf[12..14], @intCast(@mod(start, 65536)), .big);
    std.mem.writeInt(u16, buf[14..16], @intCast(count), .big);
    buf[16] = @intCast((ref_time >> 16) & 0xFF);
    buf[17] = @intCast((ref_time >> 8) & 0xFF);
    buf[18] = @intCast(ref_time & 0xFF);
    buf[19] = pkt;
    var off: usize = 20;
    for (chunks[0..ci]) |ch| {
        std.mem.writeInt(u16, buf[off..][0..2], ch, .big);
        off += 2;
    }
    @memcpy(buf[off..][0..nd], deltas[0..nd]);
    return buf[0..total];
}

/// Remonta um quadro H.264 a partir dos pacotes RTP de um SSRC.
pub const Depacketizer = struct {
    bytes: std.ArrayList(u8) = .empty,
    ts: u32 = 0,
    last_seq: u16 = 0,
    have_seq: bool = false,
    /// Depois de perder um pacote, só recomeça num quadro-chave (SPS ou IDR).
    need_key: bool = true,
    /// O quadro em montagem tem um NAL de chave.
    key: bool = false,

    pub fn deinit(d: *Depacketizer, gpa: std.mem.Allocator) void {
        d.bytes.deinit(gpa);
    }

    pub fn reset(d: *Depacketizer) void {
        d.bytes.clearRetainingCapacity();
        d.have_seq = false;
        d.need_key = true;
        d.key = false;
    }

    /// Comeu um quadro inteiro: o próximo pacote começa outro.
    pub fn consumed(d: *Depacketizer) void {
        d.bytes.clearRetainingCapacity();
        d.key = false;
    }

    pub fn frame(d: *const Depacketizer) []const u8 {
        return d.bytes.items;
    }

    /// Recebe um payload H.264 já decifrado (sem as extensões) e diz se o
    /// quadro terminou. O quadro fica em `frame` até `consumed`.
    pub fn feed(d: *Depacketizer, gpa: std.mem.Allocator, payload: []const u8, ts: u32, seq: u16, marker: bool) !bool {
        if (payload.len == 0) return false;

        if (d.have_seq and seq != d.last_seq +% 1) {
            // Pacote perdido: o quadro atual não serve mais.
            d.bytes.clearRetainingCapacity();
            d.need_key = true;
            d.key = false;
        }
        if (d.have_seq and ts != d.ts and d.bytes.items.len > 0) {
            // Chegou outro quadro sem o marcador do anterior.
            d.bytes.clearRetainingCapacity();
            d.need_key = true;
            d.key = false;
        }
        if (!d.have_seq or d.bytes.items.len == 0) d.ts = ts;
        d.have_seq = true;
        d.last_seq = seq;

        const t = payload[0] & 0x1f;
        var starts_nal = false;
        var key_start = false;
        switch (t) {
            1...23 => {
                starts_nal = true;
                key_start = t == 5 or t == 7;
            },
            24 => {
                starts_nal = true;
                key_start = stapHasKey(payload);
            },
            28, 29 => if (payload.len >= 2) {
                const fu = payload[1];
                starts_nal = fu & 0x80 != 0;
                key_start = starts_nal and ((fu & 0x1f) == 5 or (fu & 0x1f) == 7);
            },
            else => {},
        }
        // Esperando um quadro-chave: descarta tudo o que não o começa.
        if (d.need_key and !(starts_nal and key_start)) return false;

        const before = d.bytes.items.len;
        switch (t) {
            1...23 => {
                try d.appendNal(gpa, payload);
                if (key_start) d.key = true;
            },
            24 => {
                var pos: usize = 1;
                while (pos + 2 <= payload.len) {
                    const n = std.mem.readInt(u16, payload[pos..][0..2], .big);
                    pos += 2;
                    if (n == 0 or pos + n > payload.len) break;
                    try d.appendNal(gpa, payload[pos .. pos + n]);
                    const nt = payload[pos] & 0x1f;
                    if (nt == 5 or nt == 7) d.key = true;
                    pos += n;
                }
            },
            28, 29 => {
                if (payload.len < 3) return false;
                const header = payload[0];
                const fu = payload[1];
                const skip: usize = if (t == 29) 4 else 2; // FU-B traz o DON
                if (payload.len <= skip) return false;
                if (fu & 0x80 != 0) {
                    const nal = [1]u8{(header & 0xe0) | (fu & 0x1f)};
                    try d.appendNal(gpa, &nal);
                    if ((fu & 0x1f) == 5 or (fu & 0x1f) == 7) d.key = true;
                } else if (before == 0) {
                    // Fragmento do meio sem o começo: não dá para montar.
                    d.need_key = true;
                    return false;
                }
                try d.append(gpa, payload[skip..]);
            },
            else => return false,
        }
        if (d.need_key) d.need_key = false;

        if (!marker) return false;
        if (d.bytes.items.len == 0) return false;
        return true;
    }

    fn appendNal(d: *Depacketizer, gpa: std.mem.Allocator, nal: []const u8) !void {
        if (nal.len == 0) return;
        try d.append(gpa, &.{ 0, 0, 0, 1 });
        try d.append(gpa, nal);
    }

    fn append(d: *Depacketizer, gpa: std.mem.Allocator, data: []const u8) !void {
        if (d.bytes.items.len + data.len > max_frame_bytes) {
            d.bytes.clearRetainingCapacity();
            d.need_key = true;
            d.key = false;
            return error.TooBig;
        }
        try d.bytes.appendSlice(gpa, data);
    }
};

fn stapHasKey(payload: []const u8) bool {
    var pos: usize = 1;
    while (pos + 2 <= payload.len) {
        const n = std.mem.readInt(u16, payload[pos..][0..2], .big);
        pos += 2;
        if (n == 0 or pos + n > payload.len) return false;
        const t = payload[pos] & 0x1f;
        if (t == 5 or t == 7) return true;
        pos += n;
    }
    return false;
}

// --- Testes -----------------------------------------------------------------

const testing = std.testing;

test "cabeçalho RTP sem extensão" {
    var buf: [12]u8 = undefined;
    buf[0] = 0x80;
    buf[1] = 0x80 | 101; // marcação + PT 101
    std.mem.writeInt(u16, buf[2..4], 0x1234, .big);
    std.mem.writeInt(u32, buf[4..8], 9000, .big);
    std.mem.writeInt(u32, buf[8..12], 0xdeadbeef, .big);
    const h = parseHeader(&buf).?;
    try testing.expect(h.marker);
    try testing.expectEqual(@as(u8, 101), h.payload_type);
    try testing.expectEqual(@as(u16, 0x1234), h.seq);
    try testing.expectEqual(@as(u32, 9000), h.ts);
    try testing.expectEqual(@as(u32, 0xdeadbeef), h.ssrc);
    try testing.expectEqual(@as(usize, 12), h.aad_len);
    try testing.expectEqual(@as(usize, 0), h.ext_len);
    try testing.expect(!h.padding);
}

test "cabeçalho RTP com CSRC e extensão" {
    var buf: [24]u8 = @splat(0);
    buf[0] = 0x80 | 0x10 | 2; // extensão + 2 CSRC
    buf[1] = 101;
    buf[12] = 0xbe;
    buf[13] = 0xde;
    std.mem.writeInt(u16, buf[22..24], 0, .big);
    // 12 + 2*4 = 20, preâmbulo de 4 = 24.
    const h = parseHeader(&buf).?;
    try testing.expectEqual(@as(usize, 24), h.aad_len);
    try testing.expectEqual(@as(usize, 0), h.ext_len);
    std.mem.writeInt(u16, buf[22..24], 2, .big);
    const h2 = parseHeader(&buf).?;
    try testing.expectEqual(@as(usize, 8), h2.ext_len);
}

test "NAL único vira Annex-B" {
    const gpa = testing.allocator;
    var d: Depacketizer = .{};
    defer d.deinit(gpa);
    // IDR (tipo 5) num pacote só.
    try testing.expect(try d.feed(gpa, &.{ 0x65, 0xaa, 0xbb }, 1000, 1, true));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x65, 0xaa, 0xbb }, d.frame());
}

test "FU-A remonta o NAL" {
    const gpa = testing.allocator;
    var d: Depacketizer = .{};
    defer d.deinit(gpa);
    // Indicador (NRI 3, tipo 28), cabeçalho (início, tipo 5), dados.
    try testing.expect(!try d.feed(gpa, &.{ 0x7c, 0x85, 0xaa }, 1000, 1, false));
    try testing.expect(try d.feed(gpa, &.{ 0x7c, 0x45, 0xbb, 0xcc }, 1000, 2, true));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x65, 0xaa, 0xbb, 0xcc }, d.frame());
}

test "STAP-A junta NALs pequenos" {
    const gpa = testing.allocator;
    var d: Depacketizer = .{};
    defer d.deinit(gpa);
    const pkt = [_]u8{ 0x78, 0, 2, 0x67, 0x11, 0, 1, 0x65 };
    try testing.expect(try d.feed(gpa, &pkt, 1000, 1, true));
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x67, 0x11, 0, 0, 0, 1, 0x65 }, d.frame());
}

test "perda de pacote espera quadro-chave" {
    const gpa = testing.allocator;
    var d: Depacketizer = .{};
    defer d.deinit(gpa);
    try testing.expect(try d.feed(gpa, &.{ 0x65, 1 }, 1000, 10, true));
    d.consumed();
    // O seq salta: perdeu um pacote/quadro.
    try testing.expect(!try d.feed(gpa, &.{ 0x41, 2 }, 2000, 12, true));
    // P-frame não serve ainda.
    try testing.expect(!try d.feed(gpa, &.{ 0x41, 3 }, 3000, 13, true));
    // IDR recomeça.
    try testing.expect(try d.feed(gpa, &.{ 0x65, 4 }, 4000, 14, true));
}

test "extensão transport-cc (id 5)" {
    const ext = [_]u8{ 0x51, 0x12, 0x34, 0x00 };
    try testing.expectEqual(@as(?u16, 0x1234), transportSeq(&ext));
    const other = [_]u8{ 0xB1, 0xaa, 0xbb, 0x00 };
    try testing.expectEqual(@as(?u16, null), transportSeq(&other));
    try testing.expectEqual(@as(?u16, null), transportSeq(&.{}));
}

test "RTCP Receiver Report" {
    var buf: [40]u8 = undefined;
    const rr = writeRr(&buf, 0x01020304, 0x0a0b0c0d, 0x00010002, 1234, 0xdeadbeef, 65536).?;
    try testing.expectEqual(@as(usize, 32), rr.len);
    try testing.expectEqual(@as(u8, 0x81), rr[0]);
    try testing.expectEqual(@as(u8, 201), rr[1]);
    try testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, rr[2..4], .big));
    try testing.expectEqual(@as(u32, 0x01020304), std.mem.readInt(u32, rr[4..8], .big));
    try testing.expectEqual(@as(u32, 0x0a0b0c0d), std.mem.readInt(u32, rr[8..12], .big));
    try testing.expectEqual(@as(u32, 0x00010002), std.mem.readInt(u32, rr[16..20], .big));
    try testing.expectEqual(@as(u32, 1234), std.mem.readInt(u32, rr[20..24], .big));
    try testing.expectEqual(@as(u32, 0xdeadbeef), std.mem.readInt(u32, rr[24..28], .big));
    try testing.expectEqual(@as(u32, 65536), std.mem.readInt(u32, rr[28..32], .big));
    for (rr[12..16]) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "transport-cc: três pacotes seguidos, deltas em 250 µs" {
    var buf: [1024]u8 = undefined;
    const s = [_]CcSample{
        .{ .seq = 100, .us = 1_000_000 },
        .{ .seq = 101, .us = 1_005_000 },
        .{ .seq = 102, .us = 1_010_000 },
    };
    const p = writeTransportCc(&buf, 0x01020304, 0x0a0b0c0d, &s, 7).?;
    try testing.expectEqual(@as(usize, 0), p.len % 4);
    try testing.expectEqual(@as(u8, 0x8f), p[0]);
    try testing.expectEqual(@as(u8, 205), p[1]);
    try testing.expectEqual(@as(u16, 100), std.mem.readInt(u16, p[12..14], .big));
    try testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, p[14..16], .big));
    try testing.expectEqual(@as(u8, 7), p[19]);
    // Ref = 15 * 64 ms; o primeiro delta é 40 ms, os outros 5 ms.
    try testing.expectEqual(@as(u16, 0x2000), std.mem.readInt(u16, p[20..22], .big));
    try testing.expectEqual(@as(u16, 0x2000), std.mem.readInt(u16, p[22..24], .big));
    try testing.expectEqual(@as(u16, 0x2000), std.mem.readInt(u16, p[24..26], .big));
    try testing.expectEqual(@as(u8, 160), p[26]);
    try testing.expectEqual(@as(u8, 20), p[27]);
    try testing.expectEqual(@as(u8, 20), p[28]);
}

test "transport-cc: pacote que faltou entra como não recebido" {
    var buf: [1024]u8 = undefined;
    const s = [_]CcSample{
        .{ .seq = 10, .us = 2_000_000 },
        .{ .seq = 12, .us = 2_010_000 },
    };
    const p = writeTransportCc(&buf, 1, 2, &s, 0).?;
    try testing.expectEqual(@as(u16, 10), std.mem.readInt(u16, p[12..14], .big));
    try testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, p[14..16], .big));
    try testing.expectEqual(@as(u16, 0x2000), std.mem.readInt(u16, p[20..22], .big));
    try testing.expectEqual(@as(u16, 0x0000), std.mem.readInt(u16, p[22..24], .big));
    try testing.expectEqual(@as(u16, 0x2000), std.mem.readInt(u16, p[24..26], .big));
}

test "transport-cc: fora de ordem vira delta negativo" {
    var buf: [1024]u8 = undefined;
    const s = [_]CcSample{
        .{ .seq = 11, .us = 3_000_000 },
        .{ .seq = 10, .us = 3_001_000 },
    };
    const p = writeTransportCc(&buf, 1, 2, &s, 0).?;
    // A base é a menor sequência, mesmo tendo chegado depois.
    try testing.expectEqual(@as(u16, 10), std.mem.readInt(u16, p[12..14], .big));
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, p[14..16], .big));
    try testing.expectEqual(@as(u16, 0x2000), std.mem.readInt(u16, p[20..22], .big));
    try testing.expectEqual(@as(u16, 0x4000), std.mem.readInt(u16, p[22..24], .big));
}

test "transport-cc: sem amostras não manda nada" {
    var buf: [1024]u8 = undefined;
    try testing.expect(writeTransportCc(&buf, 1, 2, &.{}, 0) == null);
}

test "RTCP REMB: 6 Mbps codificado em exp/mantissa" {
    var buf: [40]u8 = undefined;
    const remb = writeRemb(&buf, 0x01020304, 0x0a0b0c0d, 6_000_000).?;
    try testing.expectEqual(@as(usize, 24), remb.len);
    try testing.expectEqual(@as(u8, 0x8f), remb[0]);
    try testing.expectEqual(@as(u8, 206), remb[1]);
    try testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, remb[2..4], .big));
    try testing.expectEqual(@as(u32, 0x01020304), std.mem.readInt(u32, remb[4..8], .big));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, remb[8..12], .big));
    try testing.expectEqualStrings("REMB", remb[12..16]);
    try testing.expectEqual(@as(u8, 1), remb[16]);
    try testing.expectEqual(@as(u32, 0x0a0b0c0d), std.mem.readInt(u32, remb[20..24], .big));
    const exp: u32 = remb[17] >> 2;
    const mant: u32 = (@as(u32, remb[17] & 0x03) << 16) | (@as(u32, remb[18]) << 8) | remb[19];
    try testing.expectEqual(@as(u32, 6_000_000), mant << @intCast(exp));
}

test "RTCP PLI" {    var buf: [16]u8 = undefined;
    const p = writePli(&buf, 0x11223344, 0x55667788).?;
    try testing.expectEqual(@as(usize, 12), p.len);
    try testing.expectEqual(@as(u8, 0x81), p[0]);
    try testing.expectEqual(@as(u8, 206), p[1]);
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, p[2..4], .big));
    try testing.expectEqual(@as(u32, 0x11223344), std.mem.readInt(u32, p[4..8], .big));
    try testing.expectEqual(@as(u32, 0x55667788), std.mem.readInt(u32, p[8..12], .big));
    try testing.expect(isRtcp(p));
    try testing.expect(!isRtcp(&.{ 0x80, 101, 0, 0, 0, 0, 0, 0 }));
}
