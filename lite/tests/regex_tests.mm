// The custom-filter regex subset is byte-based, case-insensitive and bounded by an NFA step budget.
#import <Foundation/Foundation.h>
#include "../browser/LTRegex.h"
#include <atomic>
#include <chrono>
#include <string>
#include <thread>
#include <vector>

using lite::MatchResult;
using lite::Regex;
using Clock = std::chrono::steady_clock;
static NSUInteger checks, failures;
static void Check(bool result, const char *name) {
    ++checks;
    if (!result) { ++failures; fprintf(stderr, "FAIL %s\n", name); }
}
static std::unique_ptr<Regex> Compile(std::string_view pattern) {
    std::string error;
    auto regex = Regex::Compile(pattern, error);
    if (!regex) fprintf(stderr, "Compile failed for %.*s: %s\n", (int)pattern.size(), pattern.data(), error.c_str());
    Check(regex != nullptr, "supported pattern compiles");
    return regex;
}
static MatchResult Search(const Regex &regex, std::string_view value) {
    size_t steps = 1000000;
    return regex.search(value, steps);
}

static void TestMatching(void) {
    struct Vector { const char *pattern, *value; bool matches; };
    const Vector vectors[] = {
        {"ad", "https://example/AD/script", true}, {"ad", "https://example/content", false},
        {"", "anything", true}, {"", "", true},
        {"^ad", "AD/script", true}, {"^ad", "bad", false},
        {"ad$", "bad", true}, {"ad$", "advert", false},
        {"^ad$", "Ad", true}, {"^ad$", "ad\n", false},
        {"(^)?a", "ba", true}, {"(^)+a", "ba", false}, {"(?:$)*a", "ba", true},
        {"a.b", "a/b", true}, {"a.b", "a\nb", false}, {"a.b", "a\rb", false},
        {"a*b", "b", true}, {"a+b", "b", false}, {"a+b", "AAAb", true},
        {"^a?b$", "b", true}, {"^a?b$", "aab", false},
        {"a|bc", "xxBCyy", true}, {"a|bc", "b-c", false},
        {"^(?:ab|c)+$", "abCCab", true}, {"^(?:ab|c)+$", "abdc", false},
        {"^[a-c0-2]+$", "aB201c", true}, {"^[a-c0-2]+$", "ab3", false},
        {"^[^a-c]+$", "DEF012", true}, {"^[^a-c]+$", "defB", false},
        {"^[A-Z]+$", "aBc", true}, {"^[A-Z]+$", "abc1", false},
        {"^\\d+$", "0123", true}, {"^\\d+$", "12a", false},
        {"^\\D+$", "ab/", true}, {"^\\D+$", "ab0", false},
        {"^\\w+$", "aB_09", true}, {"^\\w+$", "abc-", false},
        {"^\\W+$", "/ -", true}, {"^\\W+$", "_", false},
        {"^\\s+$", " \t\r\n\f\v", true}, {"^\\s+$", "a", false},
        {"^\\S+$", "a_0/", true}, {"^\\S+$", "a b", false},
        {"^[\\dA-F]+$", "09aBcF", true}, {"^[\\dA-F]+$", "G", false},
        {"^[^\\w]+$", "/+!", true}, {"^[^\\w]+$", "1", false},
        {"^a{2}$", "AA", true}, {"^a{2}$", "a", false},
        {"^a{0,2}$", "", true}, {"^a{0,2}$", "aaa", false},
        {"^(ab){1,2}$", "abAB", true}, {"^(ab){1,2}$", "ababab", false},
        {"^a{0}$", "", true}, {"^a{0}$", "a", false},
        {"^(a?)*b$", "aaab", true}, {"^(a*)+b$", "b", true},
        {"^a\\+b\\?c\\.js$", "a+b?c.js", true},
        {"^\\[a\\]\\{b\\}\\(c\\)\\|\\^\\$\\*\\/\\\\\\-$", "[a]{b}(c)|^$*/\\-", true},
        {"^\\n\\r\\t\\f\\v$", "\n\r\t\f\v", true},
        {"^https?://ads\\.example/(pixel|beacon)[0-9]{1,3}\\?id=", "HTTPS://ADS.EXAMPLE/pixel42?id=7", true},
        {"^https?://ads\\.example/(pixel|beacon)[0-9]{1,3}\\?id=", "https://ads.example/pixel1234?id=7", false}
    };
    for (const auto &vector : vectors) {
        auto regex = Compile(vector.pattern);
        if (regex) {
            MatchResult actual = Search(*regex, vector.value);
            bool correct = actual == (vector.matches ? MatchResult::Match : MatchResult::NoMatch);
            if (!correct) fprintf(stderr, "Pattern %s, input %s\n", vector.pattern, vector.value);
            Check(correct, "independent matching expectation");
        }
    }
}

static void TestValidation(void) {
    const char *invalid[] = {
        "(", ")", "[", "[a", "[]", "[^]", "[z-a]", "[a-\\d]", "\\",
        "*a", "+a", "?a", "^?", "$*", "a**", "a++", "a??", "a*?", "a{2}+",
        "a{33}", "a{2,33}", "a{3,2}", "a{,2}", "a{2,}", "a{", "a{q}",
        "(?=a)", "(?!a)", "(?<=a)", "(?>a)", "(?i)a", "(?<name>a)",
        "(a)\\1", "\\b", "\\B", "\\p{L}", "\\x41", "\\u0041", "\\k<name>",
        "a\nb", "a\tb", "a\x7f", "café"
    };
    for (const char *pattern : invalid) {
        std::string error;
        auto regex = Regex::Compile(pattern, error);
        if (regex || error.empty()) fprintf(stderr, "Unexpected acceptance or missing error: %s\n", pattern);
        Check(!regex && !error.empty(), "unsupported or malformed syntax is rejected with an error");
    }
    std::string error;
    std::string maxPattern = "[" + std::string(510, 'a') + "]";
    auto regex = Regex::Compile(maxPattern, error);
    Check(regex && maxPattern.size() == 512, "512 pattern bytes are accepted when the program fits");
    maxPattern.insert(1, "a");
    Check(!Regex::Compile(maxPattern, error) && !error.empty(), "513 pattern bytes are rejected");
    regex = Regex::Compile(std::string(255, 'a'), error);
    Check(regex && regex->programSize() == 256, "256 instructions including Match are accepted");
    Check(!Regex::Compile(std::string(256, 'a'), error) && !error.empty(), "257 instructions are rejected");
    regex = Regex::Compile(std::string(16, '(') + "a" + std::string(16, ')'), error);
    Check(regex != nullptr, "16 nested groups are accepted");
    Check(!Regex::Compile(std::string(17, '(') + "a" + std::string(17, ')'), error), "17 nested groups are rejected");
    regex = Regex::Compile("a{32}", error);
    Check(regex && Search(*regex, std::string(32, 'a')) == MatchResult::Match,
          "the maximum bounded repeat compiles and matches");
    Check(!Regex::Compile("(?:abcdefgh){32}", error), "repeat expansion cannot exceed the instruction limit");
    Check(!Regex::Compile("(?:a{32}){32}", error), "nested repeats cannot evade the instruction limit");
}

static void AddStrings(std::vector<std::string> &values, std::string prefix, unsigned remaining) {
    values.push_back(prefix);
    if (remaining) for (char c : std::string("aB0/ !")) AddStrings(values, prefix + c, remaining - 1);
}
static void TestDifferential(void) {
    // No newline inputs here: Lite's $ is strictly end-of-input, unlike ICU's before-final-newline
    // alternative. Unicode case folding/character classes are outside Lite's ASCII byte subset.
    const char *patterns[] = {
        "a", "Ab", "a.b", "a*b", "a+b", "a?b", "(ab)+", "(?:a|b)*", "^a", "b$",
        "^a?b?$", "a|bc", "(a|b)c", "[a-c0-2]+", "[^a/]+", "[A-Z]",
        "\\d+", "\\D+", "\\w+", "\\W+", "\\s+", "\\S+", "a{2}", "a{0,2}",
        "(?:ab){1,2}", "[a-c]{0,3}", "(a?)*b", "(a*)+b", "(a|ab)*c",
        "^[^/]+/\\d?$", "^a{0}$", "a\\+b", "a\\$b", "a\\^b", "\\.", "[\\dA-F]+", "[^\\w]+"
    };
    std::vector<std::string> values;
    AddStrings(values, "", 4);
    NSUInteger compared = 0, mismatches = 0;
    for (const char *pattern : patterns) {
        auto regex = Compile(pattern);
        NSError *error = nil;
        NSRegularExpression *reference = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithUTF8String:pattern]
            options:NSRegularExpressionCaseInsensitive error:&error];
        Check(reference != nil, "differential reference pattern compiles");
        if (!regex || !reference) continue;
        @autoreleasepool {
            for (const std::string &value : values) {
                NSString *input = [NSString stringWithUTF8String:value.c_str()];
                bool expected = [reference firstMatchInString:input options:0 range:NSMakeRange(0, input.length)] != nil;
                MatchResult actual = Search(*regex, value);
                if (actual != (expected ? MatchResult::Match : MatchResult::NoMatch)) {
                    if (mismatches < 5) fprintf(stderr, "Differential mismatch: /%s/ against '%s'\n", pattern, value.c_str());
                    ++mismatches;
                }
                ++compared;
            }
        }
    }
    Check(compared == 37 * 1555, "differential comparison exercises every bounded short string and pattern");
    Check(mismatches == 0, "the ASCII subset agrees with Foundation across the exhaustive corpus");
    printf("Regex differential comparison: %lu cases, %lu mismatches\n", (unsigned long)compared, (unsigned long)mismatches);
}

static void TestBudgets(void) {
    auto regex = Compile("^(a+)+$");
    if (!regex) return;
    std::string nearMatch(100000, 'a');
    nearMatch += '!';
    size_t steps = 100000;
    auto started = Clock::now();
    MatchResult result = regex->search(nearMatch, steps);
    double elapsedMS = std::chrono::duration<double, std::milli>(Clock::now() - started).count();
    Check(result == MatchResult::LimitExceeded && steps == 0,
          "a long pathological nonmatch stops at the explicit step budget");
    printf("Regex pathological nonmatch: 100001 bytes, 100000 steps, %.3f ms\n", elapsedMS);
    steps = 100000;
    Check(regex->search(std::string(500, 'a') + '!', steps) == MatchResult::NoMatch && steps > 0,
          "nested repetition resolves a normal-sized near miss with merged NFA states");
    steps = 0;
    Check(regex->search("aaaa!", steps) == MatchResult::LimitExceeded && steps == 0,
          "an exhausted request budget cannot underflow or restart");
    auto shared = Compile("(?:a|aa|aaa|aaaa|aaaaa)+$");
    if (!shared) return;
    steps = 100000;
    NSUInteger tried = 0;
    bool exhausted = false, matched = false;
    std::string request(511, 'a'); request += '!';
    started = Clock::now();
    for (; tried < 32; ++tried) {
        MatchResult decision = shared->search(request, steps);
        matched |= decision == MatchResult::Match;
        if (decision == MatchResult::LimitExceeded) { exhausted = true; ++tried; break; }
    }
    elapsedMS = std::chrono::duration<double, std::milli>(Clock::now() - started).count();
    Check(exhausted && !matched && steps == 0, "32 adversarial rules share one request budget rather than resetting it");
    printf("Regex adversarial shared budget: 512-byte request, %lu/32 rules, 100000 steps, %.3f ms\n",
           (unsigned long)tried, elapsedMS);
}

static void TestConcurrency(void) {
    auto regex = Compile("^https?://(?:ads|metrics)\\.example/(?:pixel|beacon)[0-9]{1,3}$");
    if (!regex) return;
    std::atomic<unsigned> mismatches{0};
    std::vector<std::thread> workers;
    for (unsigned worker = 0; worker < 4; ++worker) workers.emplace_back([&] {
        for (unsigned request = 0; request < 1000; ++request) {
            size_t steps = 100000;
            bool match = request % 2 == 0;
            MatchResult result = regex->search(match ? "https://ADS.EXAMPLE/pixel123" : "https://ordinary.example/content", steps);
            if (result != (match ? MatchResult::Match : MatchResult::NoMatch)) ++mismatches;
        }
    });
    for (auto &worker : workers) worker.join();
    Check(mismatches == 0, "one immutable compiled regex supports concurrent request-local matching state");
}

static void TestRequestCost(void) {
    std::vector<std::unique_ptr<Regex>> rules;
    for (unsigned i = 0; i < 32; ++i) {
        auto regex = Compile("metrics[-/]segment-" + std::to_string(i) + "/[a-z]{1,3}/pixel");
        if (regex) rules.push_back(std::move(regex));
    }
    if (rules.size() != 32) return;
    std::vector<std::string> requests;
    for (unsigned i = 0; i < 3000; ++i) {
        std::string url = "https://cdn.example/assets/metrics/segment/ordinary/resource-" + std::to_string(i) + ".js?v=";
        url.append(512 - url.size(), 'x');
        requests.push_back(std::move(url));
    }
    auto match = [&](const std::string &url) {
        size_t steps = 50000; // The policy reserves a separate 50,000 steps for exceptions.
        for (const auto &rule : rules) {
            MatchResult result = rule->search(url, steps);
            if (result != MatchResult::NoMatch) return result;
        }
        return MatchResult::NoMatch;
    };
    for (unsigned i = 0; i < 30; ++i) match(requests[i]);
    double total = 0, slowest = 0;
    NSUInteger mismatches = 0, limited = 0;
    for (const auto &url : requests) {
        auto started = Clock::now();
        MatchResult result = match(url);
        double elapsed = std::chrono::duration<double, std::milli>(Clock::now() - started).count();
        total += elapsed;
        if (elapsed > slowest) slowest = elapsed;
        mismatches += result == MatchResult::Match;
        limited += result == MatchResult::LimitExceeded;
    }
    double mean = total / requests.size();
#if defined(__x86_64__)
    const double budget = .700;
#else
    const double budget = .350;
#endif
    Check(mismatches == 0 && limited == 0, "32 ordinary nonmatching regex rules finish within the shared block-pass step budget");
    Check(mean < budget, "32 regex rules meet the existing architecture's mean request time budget");
    printf("Regex request cost: 32 rules, 50000 shared steps, 3000 nonmatching 512-byte requests, mean %.3f ms, slowest %.3f ms "
           "(mean budget %.3f ms), %lu limited\n", mean, slowest, budget, (unsigned long)limited);
}

static void TestAdversarialRequestCost(void) {
    std::vector<std::unique_ptr<Regex>> rules;
    for (unsigned i = 0; i < 32; ++i) {
        auto regex = Compile("(?:a|aa|aaa|aaaa|aaaaa)+$");
        if (regex) rules.push_back(std::move(regex));
    }
    if (rules.size() != 32) return;
    std::vector<std::string> requests;
    for (unsigned i = 0; i < 1000; ++i) {
        std::string url = "https://cdn.example/" + std::to_string(i) + "/";
        url.append(511 - url.size(), 'a');
        url += '!';
        requests.push_back(std::move(url));
    }
    auto match = [&](const std::string &url, size_t &steps) {
        for (const auto &rule : rules) {
            MatchResult result = rule->search(url, steps);
            if (result != MatchResult::NoMatch) return result;
        }
        return MatchResult::NoMatch;
    };
    for (unsigned i = 0; i < 30; ++i) {
        size_t steps = 50000;
        match(requests[i], steps);
    }
    double total = 0, slowest = 0;
    NSUInteger limited = 0;
    for (const auto &url : requests) {
        size_t steps = 50000;
        auto started = Clock::now();
        MatchResult result = match(url, steps);
        double elapsed = std::chrono::duration<double, std::milli>(Clock::now() - started).count();
        total += elapsed;
        if (elapsed > slowest) slowest = elapsed;
        limited += result == MatchResult::LimitExceeded && steps == 0;
    }
    double mean = total / requests.size();
#if defined(__x86_64__)
    const double budget = .700;
#else
    const double budget = .350;
#endif
    Check(limited == requests.size(), "every adversarial request exhausts the shared 50000-step block budget safely");
    Check(mean < budget, "adversarial regex requests meet the existing architecture's mean request time budget");
    printf("Regex adversarial request cost: 32 rules, 50000 shared steps, 1000 nonmatching 512-byte requests, "
           "mean %.3f ms, slowest %.3f ms (mean budget %.3f ms), %lu limited\n",
           mean, slowest, budget, (unsigned long)limited);
}

int main(void) {
    @autoreleasepool {
        TestMatching();
        TestValidation();
        TestDifferential();
        TestBudgets();
        TestConcurrency();
        TestRequestCost();
        TestAdversarialRequestCost();
        printf("%lu regex checks passed, %lu failed\n", (unsigned long)(checks - failures), (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
