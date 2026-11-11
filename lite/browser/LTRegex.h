#pragma once
#include <array>
#include <bitset>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace lite {
enum class MatchResult { NoMatch, Match, LimitExceeded };

// A small ASCII, case-insensitive Thompson NFA. Programs are immutable; every
// search owns its scratch space and shares only the caller's explicit budget.
class Regex {
    static constexpr size_t MaxPattern = 512, MaxProgram = 256, MaxDepth = 16;
    using Characters = std::bitset<256>;
    enum class Kind { Empty, Character, Begin, End, Sequence, Choice, Repeat };
    struct Node {
        Kind kind;
        Characters characters;
        std::vector<int> children;
        int minimum = 0, maximum = 0;
    };
    enum class Op { Character, Begin, End, Jump, Split, Match };
    struct Instruction {
        Op op;
        Characters characters;
        int next = -1, other = -1;
    };
    struct Patch { int instruction; bool other = false; };
    struct Fragment { int start = -1; std::vector<Patch> ends; };
    std::vector<Instruction> program_;
    int start_ = -1;

    static unsigned char Fold(unsigned char c) {
        return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c;
    }
    class Parser {
        std::string_view pattern_;
        std::string &error_;
        size_t position_ = 0, depth_ = 0;
        int fail(const char *message, size_t offset = std::string_view::npos) {
            if (offset == std::string_view::npos) offset = position_;
            if (error_.empty()) error_ = "At byte " + std::to_string(offset + 1) + ": " + message;
            return -1;
        }
        int add(Node node) { nodes.push_back(std::move(node)); return (int)nodes.size() - 1; }
        int join(Kind kind, std::vector<int> children) {
            if (children.empty()) return add({Kind::Empty, {}, {}});
            if (children.size() == 1) return children[0];
            return add({kind, {}, std::move(children)});
        }
        bool escaped(Characters &set, int &single) {
            if (position_ == pattern_.size()) { fail("unfinished escape"); return false; }
            unsigned char c = pattern_[position_++];
            single = -1;
            if (c == 'd' || c == 'D' || c == 'w' || c == 'W' || c == 's' || c == 'S') {
                if (c == 'd' || c == 'D' || c == 'w' || c == 'W')
                    for (unsigned char x = '0'; x <= '9'; ++x) set.set(x);
                if (c == 'w' || c == 'W') {
                    for (unsigned char x = 'a'; x <= 'z'; ++x) set.set(x);
                    set.set('_');
                }
                if (c == 's' || c == 'S')
                    for (unsigned char x : {' ', '\t', '\n', '\r', '\f', '\v'}) set.set(x);
                if (c == 'D' || c == 'W' || c == 'S') set.flip();
                return true;
            }
            switch (c) {
                case 'n': c = '\n'; break;
                case 'r': c = '\r'; break;
                case 't': c = '\t'; break;
                case 'f': c = '\f'; break;
                case 'v': c = '\v'; break;
                default:
                    if (std::string_view("\\/.^$*+?()[]{}|-").find((char)c) == std::string_view::npos) {
                        fail(c >= '0' && c <= '9' ? "backreferences and numeric escapes are unsupported" :
                             "unsupported escape (use escaped punctuation or d, D, w, W, s, S, n, r, t, f, v)",
                             position_ - 1);
                        return false;
                    }
            }
            single = c;
            set.set(Fold(c));
            return true;
        }
        bool classItem(Characters &set, int &single) {
            unsigned char c = pattern_[position_++];
            if (c == '\\') return escaped(set, single);
            single = c;
            set.set(Fold(c));
            return true;
        }
        int characterClass() {
            bool negate = position_ < pattern_.size() && pattern_[position_] == '^';
            if (negate) ++position_;
            Characters characters;
            bool any = false;
            while (position_ < pattern_.size()) {
                if (pattern_[position_] == ']' && any) {
                    ++position_;
                    if (negate) characters.flip();
                    return add({Kind::Character, characters, {}});
                }
                Characters item;
                int first;
                if (!classItem(item, first)) return -1;
                any = true;
                if (position_ + 1 < pattern_.size() && pattern_[position_] == '-' && pattern_[position_ + 1] != ']') {
                    ++position_;
                    Characters lastSet;
                    int last;
                    if (!classItem(lastSet, last)) return -1;
                    if (first < 0 || last < 0) return fail("character-class range endpoints must be single characters");
                    if (first > last) return fail("character-class range is reversed", position_ - 1);
                    for (int c = first; c <= last; ++c) characters.set(Fold((unsigned char)c));
                } else characters |= item;
            }
            return fail("unclosed character class (escape a literal '[')");
        }
        int atom() {
            unsigned char c = pattern_[position_++];
            if (c == '(') {
                if (++depth_ > MaxDepth) return fail("group nesting exceeds 16 levels", position_ - 1);
                if (position_ < pattern_.size() && pattern_[position_] == '?') {
                    if (position_ + 1 >= pattern_.size() || pattern_[position_ + 1] != ':')
                        return fail("only ordinary and (?:...) groups are supported; lookaround and flags are unsupported");
                    position_ += 2;
                }
                int group = expression();
                if (group < 0) return -1;
                if (position_ == pattern_.size() || pattern_[position_] != ')') return fail("unclosed group");
                ++position_; --depth_;
                return group;
            }
            if (c == '[') return characterClass();
            if (c == '^' || c == '$') return add({c == '^' ? Kind::Begin : Kind::End, {}, {}});
            if (c == '*' || c == '+' || c == '?' || c == '{' || c == '}')
                return fail("quantifier has no preceding expression (escape literal punctuation)", position_ - 1);
            if (c == ']') return fail("unmatched ']' (escape a literal bracket)", position_ - 1);
            Characters characters;
            if (c == '.') { characters.set(); characters.reset('\n'); characters.reset('\r'); }
            else if (c == '\\') { int single; if (!escaped(characters, single)) return -1; }
            else characters.set(Fold(c));
            return add({Kind::Character, characters, {}});
        }
        bool count(int &value) {
            if (position_ == pattern_.size() || pattern_[position_] < '0' || pattern_[position_] > '9') {
                fail("repeat count must be an integer from 0 to 32"); return false;
            }
            value = 0;
            while (position_ < pattern_.size() && pattern_[position_] >= '0' && pattern_[position_] <= '9') {
                value = value * 10 + (pattern_[position_++] - '0');
                if (value > 32) { fail("repeat count exceeds 32", position_ - 1); return false; }
            }
            return true;
        }
        int sequence() {
            std::vector<int> children;
            while (position_ < pattern_.size() && pattern_[position_] != ')' && pattern_[position_] != '|') {
                bool anchor = pattern_[position_] == '^' || pattern_[position_] == '$';
                int child = atom();
                if (child < 0) return -1;
                if (position_ < pattern_.size()) {
                    char c = pattern_[position_];
                    if (c == '?' || c == '*' || c == '+' || c == '{') {
                        if (anchor)
                            return fail("anchors cannot be quantified");
                        ++position_;
                        int minimum = c == '+' ? 1 : 0, maximum = c == '?' ? 1 : -1;
                        if (c == '{') {
                            if (!count(minimum)) return -1;
                            maximum = minimum;
                            if (position_ < pattern_.size() && pattern_[position_] == ',') {
                                ++position_;
                                if (!count(maximum)) return -1;
                            }
                            if (position_ == pattern_.size() || pattern_[position_] != '}')
                                return fail("repeat must use {m} or {m,n}");
                            ++position_;
                            if (minimum > maximum) return fail("repeat minimum exceeds maximum");
                        }
                        child = add({Kind::Repeat, {}, {child}, minimum, maximum});
                        if (position_ < pattern_.size() && std::string_view("?*+{").find(pattern_[position_]) != std::string_view::npos)
                            return fail("repeated, lazy, and possessive quantifiers are unsupported");
                    }
                }
                children.push_back(child);
            }
            return join(Kind::Sequence, std::move(children));
        }
        int expression() {
            std::vector<int> children;
            do {
                int child = sequence();
                if (child < 0) return -1;
                children.push_back(child);
                if (position_ == pattern_.size() || pattern_[position_] != '|') break;
                ++position_;
            } while (true);
            return join(Kind::Choice, std::move(children));
        }
    public:
        std::vector<Node> nodes;
        Parser(std::string_view pattern, std::string &error) : pattern_(pattern), error_(error) {}
        int parse() {
            int root = expression();
            if (root >= 0 && position_ != pattern_.size()) return fail("unmatched ')'");
            return root;
        }
        size_t cost(int index) const {
            const Node &node = nodes[index];
            size_t result = 0;
            if (node.kind == Kind::Repeat) {
                size_t child = cost(node.children[0]);
                result = node.maximum < 0 ? child + 1 :
                    node.maximum == 0 ? 1 : child * node.maximum + node.maximum - node.minimum;
            } else if (node.kind == Kind::Sequence || node.kind == Kind::Choice) {
                for (int child : node.children) {
                    result += cost(child);
                    if (result > MaxProgram) break;
                }
                if (node.kind == Kind::Choice) result += node.children.size() - 1;
            } else result = 1;
            return result > MaxProgram ? MaxProgram + 1 : result;
        }
    };
    int emit(Op op, int next = -1, int other = -1, Characters characters = {}) {
        program_.push_back({op, characters, next, other});
        return (int)program_.size() - 1;
    }
    void patch(const std::vector<Patch> &ends, int next) {
        for (Patch end : ends) {
            Instruction &instruction = program_[end.instruction];
            (end.other ? instruction.other : instruction.next) = next;
        }
    }
    Fragment append(Fragment first, Fragment second) {
        if (first.start < 0) return second;
        patch(first.ends, second.start);
        return {first.start, std::move(second.ends)};
    }
    Fragment compile(const std::vector<Node> &nodes, int index) {
        const Node &node = nodes[index];
        if (node.kind == Kind::Sequence) {
            Fragment result;
            for (int child : node.children) result = append(std::move(result), compile(nodes, child));
            return result;
        }
        if (node.kind == Kind::Choice) {
            Fragment result = compile(nodes, node.children[0]);
            for (size_t i = 1; i < node.children.size(); ++i) {
                Fragment next = compile(nodes, node.children[i]);
                result.start = emit(Op::Split, result.start, next.start);
                result.ends.insert(result.ends.end(), next.ends.begin(), next.ends.end());
            }
            return result;
        }
        if (node.kind == Kind::Repeat) {
            if (node.maximum < 0) {
                Fragment child = compile(nodes, node.children[0]);
                int split = emit(Op::Split, child.start);
                patch(child.ends, split);
                return {node.minimum ? child.start : split, {{split, true}}};
            }
            Fragment result;
            for (int i = 0; i < node.maximum; ++i) {
                Fragment child = compile(nodes, node.children[0]);
                if (i >= node.minimum) {
                    child.start = emit(Op::Split, child.start);
                    child.ends.push_back({child.start, true});
                }
                result = append(std::move(result), std::move(child));
            }
            if (result.start >= 0) return result;
        }
        Op op = node.kind == Kind::Character ? Op::Character : node.kind == Kind::Begin ? Op::Begin :
            node.kind == Kind::End ? Op::End : Op::Jump;
        int instruction = emit(op, -1, -1, node.characters);
        return {instruction, {{instruction}}};
    }
    struct States {
        std::array<int, MaxProgram> characters;
        std::bitset<MaxProgram> seen;
        size_t count = 0;
    };
    MatchResult closure(States &states, int start, size_t position, size_t length, size_t &budget) const {
        std::array<int, MaxProgram> pending;
        size_t count = 0;
        auto push = [&](int index) {
            if (!states.seen[index]) { states.seen[index] = true; pending[count++] = index; }
        };
        push(start);
        while (count) {
            if (!budget) return MatchResult::LimitExceeded;
            --budget;
            int index = pending[--count];
            const Instruction &instruction = program_[index];
            switch (instruction.op) {
                case Op::Character: states.characters[states.count++] = index; break;
                case Op::Jump: push(instruction.next); break;
                case Op::Split: push(instruction.next); push(instruction.other); break;
                case Op::Begin: if (position == 0) push(instruction.next); break;
                case Op::End: if (position == length) push(instruction.next); break;
                case Op::Match: return MatchResult::Match;
            }
        }
        return MatchResult::NoMatch;
    }
public:
    static std::unique_ptr<Regex> Compile(std::string_view pattern, std::string &error) {
        error.clear();
        if (pattern.size() > MaxPattern) { error = "Regular expression exceeds 512 bytes"; return nullptr; }
        for (size_t i = 0; i < pattern.size(); ++i) {
            unsigned char c = pattern[i];
            if (c >= 128 || c < 32 || c == 127) {
                error = "At byte " + std::to_string(i + 1) + (c >= 128 ?
                    ": regular expressions support ASCII patterns only" :
                    ": raw control characters are unsupported; use an explicit escape");
                return nullptr;
            }
        }
        Parser parser(pattern, error);
        int root = parser.parse();
        if (root < 0) return nullptr;
        // Compute expansion size before emitting repeated copies, including Match.
        size_t size = parser.cost(root) + 1;
        if (size > MaxProgram) { error = "Regular expression exceeds 256 compiled instructions"; return nullptr; }
        std::unique_ptr<Regex> result(new Regex);
        result->program_.reserve(size);
        Fragment fragment = result->compile(parser.nodes, root);
        int match = result->emit(Op::Match);
        result->patch(fragment.ends, match);
        result->start_ = fragment.start;
        return result;
    }
    size_t programSize() const { return program_.size(); }
    MatchResult search(std::string_view input, size_t &remainingSteps) const {
        States scratch[2];
        States *current = &scratch[0], *next = &scratch[1];
        MatchResult result = closure(*current, start_, 0, input.size(), remainingSteps);
        if (result != MatchResult::NoMatch) return result;
        for (size_t position = 0; position < input.size(); ++position) {
            next->seen.reset();
            next->count = 0;
            unsigned char c = Fold((unsigned char)input[position]);
            for (size_t i = 0; i < current->count; ++i) {
                if (!remainingSteps) return MatchResult::LimitExceeded;
                --remainingSteps;
                const Instruction &instruction = program_[current->characters[i]];
                if (instruction.characters[c]) {
                    result = closure(*next, instruction.next, position + 1, input.size(), remainingSteps);
                    if (result != MatchResult::NoMatch) return result;
                }
            }
            // Merge every possible starting position into the same active set.
            result = closure(*next, start_, position + 1, input.size(), remainingSteps);
            if (result != MatchResult::NoMatch) return result;
            std::swap(current, next);
        }
        return MatchResult::NoMatch;
    }
};
} // namespace lite
