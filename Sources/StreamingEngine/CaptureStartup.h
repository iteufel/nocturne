#pragma once
#import <Foundation/Foundation.h>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>

namespace nocturne {
    // SDK completions can arrive after a startup deadline. Shared ownership keeps
    // their state alive; an expired operation never retains a late result.
    // This helper is compiled with the capture backend's manual reference counting.
    class CaptureStartup {
    public:
        ~CaptureStartup() { [value_ release]; }
        bool finish(id value) {
            std::lock_guard<std::mutex> lock(mutex_);
            if (expired_) return false;
            if (!completed_) {
                value_ = [value retain];
                completed_ = true;
                ready_.notify_one();
            }
            return true;
        }
        bool wait() {
            std::unique_lock<std::mutex> lock(mutex_);
            if (ready_.wait_for(lock, std::chrono::seconds(5), [&] { return completed_; })) return true;
            expired_ = true;
            return false;
        }
        id copyValue() {
            std::lock_guard<std::mutex> lock(mutex_);
            return [value_ retain];
        }
    private:
        std::mutex mutex_;
        std::condition_variable ready_;
        bool completed_ = false, expired_ = false;
        id value_ = nil;
    };
}
