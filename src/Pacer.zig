//! Limits the rate of outgoing messages to at most `limit` messages in any
//! one-second window. TWS disconnects clients that send more than 50
//! messages per second.
//!
//! The pacer only computes delays; the caller sleeps. It is not thread-safe.

const Pacer = @This();

const std = @import("std");
const Io = std.Io;

/// Largest supported limit.
pub const max_limit = 255;

/// Length of the window.
pub const window: Io.Duration = .fromSeconds(1);

/// Messages allowed per window; 0 disables pacing.
limit: u8,
/// Ring buffer with the send times of the last `count` messages. Only the
/// first `limit` slots are used; the rest stay unused.
times: [max_limit]Io.Timestamp = undefined,
/// Index of the oldest entry in `times`. Stays 0 while the buffer fills up;
/// once it is full, `record` overwrites the oldest entry and moves `head`
/// to the next one, which becomes the oldest.
head: usize = 0,
/// Number of valid entries in `times`. Grows up to `limit` and then stays
/// there; entries are never removed, only overwritten. Old entries need no
/// removal: `delay` only compares the oldest one with the current time.
count: usize = 0,

/// Creates a pacer allowing `limit` messages per second (0 = unlimited).
pub fn init(limit: u8) Pacer {
    return .{ .limit = limit };
}

/// How long to wait before a message may be sent at `now`; null if it may
/// be sent right away.
pub fn delay(p: *const Pacer, now: Io.Timestamp) ?Io.Duration {
    if (p.limit == 0 or p.count < p.limit) return null;
    const ready = p.times[p.head].addDuration(window);
    const wait = now.durationTo(ready);
    return if (wait.toNanoseconds() > 0) wait else null;
}

/// Records a message sent at `now`.
pub fn record(p: *Pacer, now: Io.Timestamp) void {
    if (p.limit == 0) return;
    if (p.count < p.limit) {
        p.times[(p.head + p.count) % p.limit] = now;
        p.count += 1;
    } else {
        p.times[p.head] = now;
        p.head = (p.head + 1) % p.limit;
    }
}

const testing = std.testing;

fn ms(n: i64) Io.Timestamp {
    return .fromNanoseconds(@as(i96, n) * std.time.ns_per_ms);
}

test "messages within the limit are not delayed" {
    var p: Pacer = .init(3);
    for (0..3) |i| {
        try testing.expectEqual(@as(?Io.Duration, null), p.delay(ms(@intCast(i * 10))));
        p.record(ms(@intCast(i * 10)));
    }
    // The fourth message waits until the first leaves the window.
    try testing.expectEqual(@as(i64, 970), p.delay(ms(30)).?.toMilliseconds());
    try testing.expectEqual(@as(?Io.Duration, null), p.delay(ms(1000)));
    p.record(ms(1000));
    // Now the oldest is the second message (10 ms).
    try testing.expectEqual(@as(i64, 10), p.delay(ms(1000)).?.toMilliseconds());
    p.record(ms(1010));
    p.record(ms(1020));
    try testing.expectEqual(@as(i64, 980), p.delay(ms(1020)).?.toMilliseconds());
}

test "a zero limit disables pacing" {
    var p: Pacer = .init(0);
    for (0..1000) |_| {
        try testing.expectEqual(@as(?Io.Duration, null), p.delay(ms(0)));
        p.record(ms(0));
    }
}
