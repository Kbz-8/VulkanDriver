//! Atomic based spin mutex
const std = @import("std");

mutex: std.atomic.Mutex = .unlocked,

pub fn lock(self: *@This()) void {
    if (self.mutex.tryLock()) {
        @branchHint(.likely);
        return;
    }

    while (true) {
        if (self.mutex.tryLock()) {
            return;
        }
    }
}

pub fn unlock(self: *@This()) void {
    self.mutex.unlock();
}
