--[[
Luma typo correction.

The luma_typo translator reads a prism with single-edit typo spellings (swapped, doubled,
dropped or neighbouring keys, z/zh, an/ang) and sits OFFSET below the main translator's
quality, so its words are easy to tell apart; sentences carry no quality, so a correction is
recognised by its pinyin (from spelling hints) not matching the typed syllables. This filter
decides where corrections go:

  * If the typed syllables already spell a word, it leads. A correction joins the first page
    only when it is far more plausible, and takes first place only when overwhelmingly so
    (an obscure word typed by accident); the rest open the second page.
  * Otherwise the best correction competes with the exact sentence on log-probability,
    scored the way the sentence maker scores words, and the more likely one leads.

Corrections that are shown get a comment of "\1" followed by the pinyin they stand for,
which the candidate panel turns into a quiet hint. The option `luma_typo_off` turns them
off without redeploying.
--]]

local OFFSET = 100                         -- keep in sync with scripts/make_typo_schema.py
local WORD = -13.815510557964274           -- log(1e-6): what the sentence maker charges per word
local LOOKAHEAD = 40                       -- full-length candidates weighed per keystroke
-- Tuned on generated typos and correctly typed text (see scripts/eval_typo.sh):
local LEAD_COST = -10.0     -- log-cost per corrected syllable when competing for first place
local REST_COST = -6.0      -- ... and for a place among the first page's full-length candidates
local WORD_MARGIN = 8.0     -- extra lead needed to displace a typed word that really exists
local DEBUG = os.getenv("LUMA_TYPO_DEBUG") ~= nil

local function is_typo(c)
    return c.quality < -OFFSET / 2
end

local function split(s)
    local t = {}
    for w in s:gmatch("[^%s']+") do t[#t + 1] = w:gsub("ü", "v"):gsub("([jqxy])u", "%1v") end
    return t
end

-- "exact" when every typed chunk spells its syllable; "partial" when a chunk is an
-- abbreviation (no vowel, like "zh") or the last chunk is still being typed, or the word runs
-- past the input (completion); "typo" otherwise, with the number of corrected syllables.
-- nil when the candidate carries no pinyin.
local function kind(c)
    local pinyin = c.comment:match("^［(.-)］$") or c.comment:match("^\1(.+)$")
    if not pinyin then return nil, nil end
    local typed, want = split(c.preedit), split(pinyin)
    if #typed > #want then return "typo", pinyin, #typed - #want end
    local result, fixes = (#typed < #want) and "partial" or "exact", 0
    for i = 1, #typed do
        local t, w = typed[i], want[i]
        if t ~= w then
            local prefix = w:sub(1, #t) == t
            if prefix and (i == #typed or not t:find("[aeiouv]")) then
                result = result == "exact" and "partial" or result
            else
                fixes = fixes + 1
            end
        end
    end
    if fixes > 0 then return "typo", pinyin, fixes end
    return result, pinyin, 0
end

-- Log-probability on the sentence maker's scale: a lone word pays one word's cost, and
-- each corrected syllable pays `cost` on top of the prism's own penalty.
local memo = {}  -- candidate -> { base score, corrected syllables }; reset per arrangement

local function score(c, cost)
    local m = memo[c]
    if not m then
        local p = c:to_phrase()
        local _, _, fixes = kind(c)
        m = { p and (c.type == "sentence" and p.weight or p.weight + WORD), fixes or 0 }
        memo[c] = m
    end
    if not m[1] then return nil end
    return m[1] + m[2] * (cost or 0)
end

-- Merges corrections into the exact list by score; exact entries without a score (other
-- translators) keep their place ahead of corrections.
local function merge_by_score(exact, typo, cost)
    local out, i, j = {}, 1, 1
    local function es(c) return score(c) or math.huge end
    local function ts(c) return score(c, cost) or -math.huge end
    while i <= #exact or j <= #typo do
        if j > #typo or (i <= #exact and es(exact[i]) >= ts(typo[j])) then
            out[#out + 1] = exact[i]; i = i + 1
        else
            out[#out + 1] = typo[j]; j = j + 1
        end
    end
    return out
end

local function mark(c)
    local k, pinyin = kind(c)
    if k == "typo" then
        c.comment = "\1" .. pinyin:gsub("'", " ")
    end
end

local function arrange(held)
    memo = {}
    if DEBUG then
        for _, c in ipairs(held) do
            io.stderr:write(string.format("  held %s %s q=%.2f %s %s\n", c.text, c.type, c.quality,
                c.preedit, c.comment))
        end
    end
    -- Sentences carry no quality, so a correction is recognised by its pinyin not matching
    -- the typed syllables; the quality offset only tells the typo translator's words apart.
    local exact, typo, texts, kinds = {}, {}, {}, {}
    for i, c in ipairs(held) do
        kinds[i] = kind(c)
        if is_typo(c) then
            c.quality = c.quality + OFFSET
            -- The typo translator's uncorrected words duplicate the main translator's.
            if kinds[i] ~= "typo" then kinds[i] = "skip" end
        end
    end
    for i, c in ipairs(held) do
        if kinds[i] ~= "typo" and kinds[i] ~= "skip" and not texts[c.text] then
            texts[c.text] = true
            exact[#exact + 1] = c
        end
    end
    for i, c in ipairs(held) do
        if kinds[i] == "typo" and not texts[c.text] then
            texts[c.text] = true
            mark(c)
            typo[#typo + 1] = c
        end
    end
    if #typo == 0 then return exact, {} end

    local real_word, single = false, false
    for _, c in ipairs(exact) do
        if c.type ~= "sentence" and c.type ~= "completion" then
            -- Pinyin that spells a word exactly, or a word from another translator
            -- (English, custom phrases), which carries no pinyin comment.
            local k, pinyin = kind(c)
            if k == "exact" or k == nil then
                real_word = true
                single = pinyin ~= nil and #split(pinyin) == 1
                break
            end
        end
    end

    table.sort(typo, function(a, b) return (score(a, REST_COST) or -math.huge) > (score(b, REST_COST) or -math.huge) end)
    if DEBUG then
        for _, c in ipairs(typo) do
            local p = c:to_phrase()
            io.stderr:write(string.format("  typo %s w=%.2f score=%.2f fixes=%s\n", c.text, p and p.weight or 0,
                score(c, REST_COST) or 0, tostring(memo[c] and memo[c][2])))
        end
    end
    local out, deferred = nil, {}
    if real_word then
        -- A real word was typed: it leads, and a correction only joins the full-length
        -- candidates when it is far more plausible than that word (REST_COST per fix).
        -- The rest wait until after every exact candidate, partial ones included.
        local lead_score = score(exact[1]) or math.huge
        local strong = {}
        for _, c in ipairs(typo) do
            if not single and (score(c, REST_COST) or -math.huge) > lead_score then
                strong[#strong + 1] = c
            else
                deferred[#deferred + 1] = c
            end
        end
        -- An obscure typed word still gives way to an overwhelmingly likelier correction.
        out = {}
        if strong[1] and (score(strong[1], LEAD_COST) or -math.huge) > lead_score + WORD_MARGIN then
            out[1] = table.remove(strong, 1)
        end
        out[#out + 1] = exact[1]
        local rest = {}
        for i = 2, #exact do rest[#rest + 1] = exact[i] end
        for _, c in ipairs(merge_by_score(rest, strong, REST_COST)) do out[#out + 1] = c end
    else
        local best, best_score = nil, -math.huge
        for i, c in ipairs(typo) do
            local s = score(c, LEAD_COST)
            if s and s > best_score then best, best_score = i, s end
        end
        local lead = exact[1]
        local lead_score = lead and score(lead) or -math.huge
        if DEBUG then
            io.stderr:write(string.format("luma_typo: exact %s %.2f, typo %s %.2f\n",
                lead and lead.text or "-", lead_score, best and typo[best].text or "-", best_score))
        end
        out = {}
        if best and best_score > lead_score then
            out[1] = table.remove(typo, best)
            if lead then out[2] = lead end
        elseif lead then
            out[1] = lead
        end
        local rest = {}
        for i = 2, #exact do rest[#rest + 1] = exact[i] end
        for _, c in ipairs(merge_by_score(rest, typo, REST_COST)) do out[#out + 1] = c end
    end
    return out, deferred
end

local function filter(input, env)
    local off = env.engine.context:get_option("luma_typo_off")
    local page = env.engine.schema.page_size
    local held, first_end, streaming, shown, deferred, queued = {}, nil, false, {}, {}, {}
    local count = 0
    local function show(list)
        for _, c in ipairs(list) do
            shown[c.text] = true
            count = count + 1
            yield(c)
        end
    end
    local function queue(list)
        for _, c in ipairs(list) do queued[c.text] = true end
    end
    -- Weaker corrections open the second page, after every first-page exact candidate.
    local function flush_deferred()
        local pending = {}
        for _, c in ipairs(deferred) do
            if not shown[c.text] then pending[#pending + 1] = c end
        end
        deferred = {}
        show(pending)
    end
    for cand in input:iter() do
        if off then
            if not is_typo(cand) then yield(cand) end
        elseif not streaming then
            first_end = first_end or cand._end
            if cand._end == first_end and #held < LOOKAHEAD then
                held[#held + 1] = cand
            else
                local arranged
                arranged, deferred = arrange(held)
                show(arranged)
                queue(deferred)
                streaming = true
            end
        end
        if streaming and not off and not shown[cand.text] then
            -- Past the full-length group, corrections covering only part of the input
            -- would crowd out exact ones; they go to the very end.
            local k = kind(cand)
            if is_typo(cand) then
                cand.quality = cand.quality + OFFSET
                if k ~= "typo" then k = "skip" end
            end
            if k == "typo" then
                if not queued[cand.text] then
                    mark(cand)
                    queued[cand.text] = true
                    deferred[#deferred + 1] = cand
                end
            elseif k ~= "skip" then  -- exact wins over a queued correction with the same text
                if count >= page then flush_deferred() end
                show({ cand })
            end
        end
    end
    if not off and not streaming then
        local arranged
        arranged, deferred = arrange(held)
        show(arranged)
    end
    flush_deferred()
end

return filter
