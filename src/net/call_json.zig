//! Calls em DM e grupo: o que vai e o que vem do gateway, sem rede (testável).
//! Numa DM não há servidor: o op 4 manda `guild_id` null e o gateway de voz
//! recebe o próprio canal como `server_id`.
const std = @import("std");
const j = @import("jsonx.zig");
const ev = @import("../core/event.zig");
const Id = @import("../core/types.zig").Id;

fn flag(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// Op 4 do gateway principal: entra (`channel`) ou sai (null) da call.
/// `guild` 0 = DM ou grupo.
pub fn voiceState(buf: []u8, guild: Id, channel: ?Id, mute: bool, deaf: bool) ?[]const u8 {
    var gb: [24]u8 = undefined;
    const g = if (guild != 0) std.fmt.bufPrint(&gb, "\"{d}\"", .{guild}) catch return null else "null";
    var cb: [24]u8 = undefined;
    const ch = if (channel) |cid| std.fmt.bufPrint(&cb, "\"{d}\"", .{cid}) catch return null else "null";
    return std.fmt.bufPrint(buf, "{{\"op\":4,\"d\":{{\"guild_id\":{s},\"channel_id\":{s},\"self_mute\":{s},\"self_deaf\":{s}}}}}", .{ g, ch, flag(mute), flag(deaf) }) catch null;
}

/// `server_id` do IDENTIFY e do RESUME da voz: o servidor, ou o canal numa DM.
pub fn serverId(guild: Id, channel: Id) Id {
    return if (guild != 0) guild else channel;
}

/// Chave de um Go Live: `guild:<servidor>:<canal>:<dono>` ou `call:<canal>:<dono>`.
pub fn streamKey(buf: []u8, guild: Id, channel: Id, owner: Id) ?[]const u8 {
    if (guild != 0) return std.fmt.bufPrint(buf, "guild:{d}:{d}:{d}", .{ guild, channel, owner }) catch null;
    return std.fmt.bufPrint(buf, "call:{d}:{d}", .{ channel, owner }) catch null;
}

/// Op 15: pede um SSRC no stream (ou na call). No Go Live manda também o
/// tamanho em pixels que a janela desenha: o SFU usa isso para escolher a
/// qualidade da codificação.
pub fn writeSinkWant(out: *std.ArrayList(u8), a: std.mem.Allocator, ssrc: u32, quality: u8, stream: bool) !void {
    if (stream and quality != 0) {
        try out.print(a, "{{\"op\":15,\"d\":{{\"{d}\":{d},\"any\":100,\"pixelCounts\":{{\"{d}\":2073600}}}}}}", .{ ssrc, quality, ssrc });
    } else {
        try out.print(a, "{{\"op\":15,\"d\":{{\"{d}\":{d},\"any\":0}}}}", .{ ssrc, quality });
    }
}

/// Op 15 com vários SSRCs de uma vez (a grade da call): cada um na qualidade
/// pedida, e `any` diz o que fazer com os outros. No Go Live vai também o
/// tamanho em pixels, que o SFU usa para escolher a codificação.
pub fn writeSinkWants(out: *std.ArrayList(u8), a: std.mem.Allocator, ssrcs: []const u32, quality: u8, stream: bool) !void {
    try out.appendSlice(a, "{\"op\":15,\"d\":{");
    for (ssrcs) |ssrc| try out.print(a, "\"{d}\":{d},", .{ ssrc, quality });
    try out.print(a, "\"any\":{d}", .{if (stream and ssrcs.len > 0) @as(u8, 100) else 0});
    if (stream and quality != 0 and ssrcs.len > 0) {
        try out.appendSlice(a, ",\"pixelCounts\":{");
        for (ssrcs, 0..) |ssrc, i| {
            if (i > 0) try out.append(a, ',');
            try out.print(a, "\"{d}\":2073600", .{ssrc});
        }
        try out.append(a, '}');
    }
    try out.appendSlice(a, "}}");
}

/// Op 0 do gateway de voz. O texto leva o token: quem chama apaga depois.
pub fn writeIdentify(out: *std.ArrayList(u8), a: std.mem.Allocator, server_id: Id, channel_id: Id, user: Id, session: []const u8, token: []const u8, max_dave: u16) !void {
    try out.print(a, "{{\"op\":0,\"d\":{{\"server_id\":\"{d}\",\"channel_id\":\"{d}\",\"user_id\":\"{d}\",\"session_id\":", .{ server_id, channel_id, user });
    try j.writeString(out, a, session);
    try out.appendSlice(a, ",\"token\":");
    try j.writeString(out, a, token);
    try out.print(a, ",\"video\":true,\"max_dave_protocol_version\":{d}}}}}", .{max_dave});
}

/// Op 1: escolhe o transporte UDP e diz o que sabemos decodificar. Em vídeo
/// só recebemos H.264 (o que o cliente oficial manda); o tipo 120 é o Opus.
pub fn writeSelectProtocol(out: *std.ArrayList(u8), a: std.mem.Allocator, ip: []const u8, port: u16) !void {
    try out.appendSlice(a, "{\"op\":1,\"d\":{\"protocol\":\"udp\",\"data\":{\"address\":");
    try j.writeString(out, a, ip);
    var b: [96]u8 = undefined;
    const tail = try std.fmt.bufPrint(&b, ",\"port\":{d},\"mode\":\"aead_xchacha20_poly1305_rtpsize\"}},\"codecs\":[", .{port});
    try out.appendSlice(a, tail);
    try out.appendSlice(a, codecs_json);
    try out.appendSlice(a, "]}}");
}

/// Ordem de preferência: o servidor escolhe o menor `priority` que todos
/// decodificam. H.264 é o padrão do Discord e o único que decodificamos.
const codecs_json =
    "{\"name\":\"opus\",\"type\":\"audio\",\"priority\":1000,\"payload_type\":120}," ++
    "{\"name\":\"H264\",\"type\":\"video\",\"priority\":1000,\"payload_type\":101,\"rtx_payload_type\":102,\"encode\":false,\"decode\":true}";

/// Op 7: retoma a sessão de voz depois de uma queda.
pub fn writeResume(out: *std.ArrayList(u8), a: std.mem.Allocator, server_id: Id, channel_id: Id, session: []const u8, token: []const u8, seq_ack: i64) !void {
    try out.print(a, "{{\"op\":7,\"d\":{{\"server_id\":\"{d}\",\"channel_id\":\"{d}\",\"session_id\":", .{ server_id, channel_id });
    try j.writeString(out, a, session);
    try out.appendSlice(a, ",\"token\":");
    try j.writeString(out, a, token);
    try out.print(a, ",\"seq_ack\":{d}}}}}", .{seq_ack});
}

/// POST /channels/{id}/call/ring: toca para todo mundo da conversa.
pub const ring_body = "{\"recipients\":null}";

/// POST /channels/{id}/call/stop-ringing: recusar (para de tocar só para nós).
pub fn stopRingingBody(buf: []u8, me: Id) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{{\"recipients\":[\"{d}\"]}}", .{me}) catch null;
}

/// CALL_CREATE / CALL_UPDATE (`ended` = CALL_DELETE). null = sem canal.
pub fn parse(d: std.json.Value, me: Id, ended: bool) ?ev.Call {
    const ch = j.id(j.get(d, "channel_id")) orelse return null;
    var out: ev.Call = .{ .channel = ch, .ended = ended };
    if (ended) return out;
    for (j.array(j.get(d, "ringing"))) |u| {
        const uid = j.id(u) orelse continue;
        if (uid == me) out.ringing_me = true else out.ringing +|= 1;
    }
    return out;
}

// --- Testes ----------------------------------------------------------------

const t = std.testing;

test "op 4 numa DM: guild_id null e o canal da conversa" {
    var b: [256]u8 = undefined;
    try t.expectEqualStrings(
        "{\"op\":4,\"d\":{\"guild_id\":null,\"channel_id\":\"900001\",\"self_mute\":false,\"self_deaf\":true}}",
        voiceState(&b, 0, 900001, false, true).?,
    );
    // Sair da call da DM: os dois null.
    try t.expectEqualStrings(
        "{\"op\":4,\"d\":{\"guild_id\":null,\"channel_id\":null,\"self_mute\":true,\"self_deaf\":false}}",
        voiceState(&b, 0, null, true, false).?,
    );
}

test "op 4 num servidor continua com o guild_id" {
    var b: [256]u8 = undefined;
    try t.expectEqualStrings(
        "{\"op\":4,\"d\":{\"guild_id\":\"81384788765712384\",\"channel_id\":\"500014\",\"self_mute\":false,\"self_deaf\":false}}",
        voiceState(&b, 81384788765712384, 500014, false, false).?,
    );
    // Sem espaço: não manda um JSON cortado.
    var tiny: [20]u8 = undefined;
    try t.expect(voiceState(&tiny, 1, 2, false, false) == null);
}

test "IDENTIFY e RESUME da voz: server_id é o canal numa DM" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeIdentify(&out, a, 900001, 900001, 1000, "sess", "tk\"x", 1);
    try t.expectEqualStrings(
        "{\"op\":0,\"d\":{\"server_id\":\"900001\",\"channel_id\":\"900001\",\"user_id\":\"1000\",\"session_id\":\"sess\",\"token\":\"tk\\\"x\",\"video\":true,\"max_dave_protocol_version\":1}}",
        out.items,
    );
    out.clearRetainingCapacity();
    try writeIdentify(&out, a, 42, 500014, 1000, "s", "t", 1);
    try t.expect(std.mem.indexOf(u8, out.items, "\"server_id\":\"42\"") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "\"channel_id\":\"500014\"") != null);
    out.clearRetainingCapacity();
    try writeResume(&out, a, 900001, 900001, "s", "t", 7);
    try t.expectEqualStrings("{\"op\":7,\"d\":{\"server_id\":\"900001\",\"channel_id\":\"900001\",\"session_id\":\"s\",\"token\":\"t\",\"seq_ack\":7}}", out.items);
    try t.expectEqual(@as(Id, 900001), serverId(0, 900001));
    try t.expectEqual(@as(Id, 42), serverId(42, 900001));
}

test "SELECT PROTOCOL diz que só decodificamos H.264" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeSelectProtocol(&out, a, "203.0.113.7", 50001);
    try t.expectEqualStrings(
        "{\"op\":1,\"d\":{\"protocol\":\"udp\",\"data\":{\"address\":\"203.0.113.7\",\"port\":50001,\"mode\":\"aead_xchacha20_poly1305_rtpsize\"},\"codecs\":[" ++
            "{\"name\":\"opus\",\"type\":\"audio\",\"priority\":1000,\"payload_type\":120}," ++
            "{\"name\":\"H264\",\"type\":\"video\",\"priority\":1000,\"payload_type\":101,\"rtx_payload_type\":102,\"encode\":false,\"decode\":true}]}}",
        out.items,
    );
}

test "op 15: no Go Live pede pixels, na call só o SSRC" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeSinkWant(&out, a, 55059, 100, true);
    try t.expectEqualStrings(
        "{\"op\":15,\"d\":{\"55059\":100,\"any\":100,\"pixelCounts\":{\"55059\":2073600}}}",
        out.items,
    );
    out.clearRetainingCapacity();
    try writeSinkWant(&out, a, 55059, 100, false);
    try t.expectEqualStrings("{\"op\":15,\"d\":{\"55059\":100,\"any\":0}}", out.items);
    // Qualidade 0 num stream desliga o pedido: nada de pixels.
    out.clearRetainingCapacity();
    try writeSinkWant(&out, a, 55059, 0, true);
    try t.expectEqualStrings("{\"op\":15,\"d\":{\"55059\":0,\"any\":0}}", out.items);
}

test "op 15: vários SSRCs de uma vez, com pixels no Go Live" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const list = [_]u32{ 55059, 55060 };
    try writeSinkWants(&out, a, &list, 100, true);
    try t.expectEqualStrings(
        "{\"op\":15,\"d\":{\"55059\":100,\"55060\":100,\"any\":100,\"pixelCounts\":{\"55059\":2073600,\"55060\":2073600}}}",
        out.items,
    );
    out.clearRetainingCapacity();
    try writeSinkWants(&out, a, &list, 100, false);
    try t.expectEqualStrings("{\"op\":15,\"d\":{\"55059\":100,\"55060\":100,\"any\":0}}", out.items);
    // Ninguém assistido: só o "any": 0.
    out.clearRetainingCapacity();
    try writeSinkWants(&out, a, &.{}, 100, true);
    try t.expectEqualStrings("{\"op\":15,\"d\":{\"any\":0}}", out.items);
}

test "stream key de Go Live: guild e call" {
    var b: [96]u8 = undefined;
    try t.expectEqualStrings("guild:839502008108580904:850360749460553769:852892297661906993", streamKey(&b, 839502008108580904, 850360749460553769, 852892297661906993).?);
    try t.expectEqualStrings("call:1110739331624210483:852892297661906993", streamKey(&b, 0, 1110739331624210483, 852892297661906993).?);
    var tiny: [8]u8 = undefined;
    try t.expect(streamKey(&tiny, 0, 1110739331624210483, 852892297661906993) == null);
}

test "recusar: stop-ringing só com o nosso id" {
    var b: [64]u8 = undefined;
    try t.expectEqualStrings("{\"recipients\":[\"1000\"]}", stopRingingBody(&b, 1000).?);
    try t.expectEqualStrings("{\"recipients\":null}", ring_body);
}

test "CALL_CREATE / CALL_UPDATE / CALL_DELETE" {
    const a = t.allocator;
    const create =
        \\{"channel_id":"900001","message_id":"77","region":"brazil","ringing":["1000","1003"],"voice_states":[{"user_id":"1001","channel_id":"900001"}]}
    ;
    const p1 = try std.json.parseFromSlice(std.json.Value, a, create, .{});
    defer p1.deinit();
    const c1 = parse(p1.value, 1000, false).?;
    try t.expectEqual(@as(Id, 900001), c1.channel);
    try t.expect(c1.ringing_me and !c1.ended);
    try t.expectEqual(@as(u8, 1), c1.ringing);
    // Atendeu em outro aparelho (ou recusou): sai do `ringing`.
    const p2 = try std.json.parseFromSlice(std.json.Value, a, "{\"channel_id\":\"900001\",\"ringing\":[]}", .{});
    defer p2.deinit();
    const c2 = parse(p2.value, 1000, false).?;
    try t.expect(!c2.ringing_me and c2.ringing == 0);
    const p3 = try std.json.parseFromSlice(std.json.Value, a, "{\"channel_id\":\"900001\",\"unavailable\":false}", .{});
    defer p3.deinit();
    try t.expect(parse(p3.value, 1000, true).?.ended);
    // Sem canal não vale.
    const p4 = try std.json.parseFromSlice(std.json.Value, a, "{\"ringing\":[\"1000\"]}", .{});
    defer p4.deinit();
    try t.expect(parse(p4.value, 1000, false) == null);
}
