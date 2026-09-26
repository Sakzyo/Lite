#pragma once
#include "include/cef_response_filter.h"
#include <algorithm>
#include <cstring>
#include <string>

// YouTube carries pre-roll instructions in the page and player API responses.
// Rename only JSON property keys, before scripts can consume them. Same-length
// replacements preserve response lengths; media URLs and payloads are untouched.
// See uBlockOrigin/uAssets filters/filters.txt and filters/quick-fixes.txt.
class LTYouTubeFilter : public CefResponseFilter {
  public:
    bool InitFilter() override { return true; }
    FilterStatus Filter(void *input, size_t inputSize, size_t &read,
                        void *output, size_t outputSize, size_t &written) override {
        read = written = 0;
        while (written < outputSize) {
            if (!ready_.empty()) {
                size_t count = std::min(outputSize - written, ready_.size());
                memcpy(static_cast<char *>(output) + written, ready_.data(), count);
                ready_.erase(0, count);
                written += count;
            } else if (read < inputSize) {
                char c = static_cast<char *>(input)[read++];
                bool start = (c == '"' && !escaped_) ||
                    (c == '\\' && !escaped_ && (previous_ == '{' || previous_ == ','));
                if (pending_.empty() && !start) ready_ += c;
                else { pending_ += c; Process(false); }
                escaped_ = c == '\\' && !escaped_;
                if (c != ' ' && c != '\t' && c != '\r' && c != '\n') previous_ = c;
            } else {
                if (inputSize == 0 && !pending_.empty()) Process(true);
                else break;
            }
        }
        return pending_.empty() && ready_.empty() ? RESPONSE_FILTER_DONE
                                                 : RESPONSE_FILTER_NEED_MORE_DATA;
    }

  private:
    std::string pending_, ready_;
    bool escaped_ = false;
    char previous_ = 0;
    void Process(bool finished) {
        for (const char *key : {"\"adPlacements\"", "\"adSlots\"", "\"playerAds\"",
                               "\\\"adPlacements\\\"", "\\\"adSlots\\\"", "\\\"playerAds\\\""}) {
            size_t length = strlen(key);
            if (pending_.compare(0, std::min(length, pending_.size()), key,
                                 std::min(length, pending_.size())) != 0) continue;
            if (pending_.size() < length) {
                if (!finished) return;
                break;
            }
            size_t end = pending_.find_first_not_of(" \t\r\n", length);
            if (end == std::string::npos && !finished && pending_.size() < 64) return;
            if (end != std::string::npos && pending_[end] == ':') {
                if (key[0] == '\\') {
                    // Serialized playerResponse objects use escaped quotes. Require
                    // an object/array value as well as a structural key boundary.
                    size_t value = pending_.find_first_not_of(" \t\r\n", end + 1);
                    if (value == std::string::npos && !finished && pending_.size() < 64) return;
                    if (value != std::string::npos && (pending_[value] == '[' || pending_[value] == '{'))
                        pending_[2] = '_';
                } else pending_[1] = '_';
            }
            break;
        }
        // Reconsider a final quote on a failed match: it might start the next key.
        bool quote = !finished && !escaped_ && pending_.size() > 1 && pending_.back() == '"';
        if (quote) {
            ready_.append(pending_, 0, pending_.size() - 1);
            pending_ = "\"";
        } else {
            ready_ += pending_;
            pending_.clear();
        }
    }
    IMPLEMENT_REFCOUNTING(LTYouTubeFilter);
};
