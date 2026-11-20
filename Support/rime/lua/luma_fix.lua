--[[
Luma: fixes the function words the sentence maker gets wrong most often, with rules narrow
enough to be right nearly every time (scripts/eval_daily.sh measures them):

  * 吧, not 把, at the end of what was typed: 我们继续吧. 把 takes an object, so it can't end a
    clause, except as a measure word or a noun (一把, 拖把), which keep it.
  * 一下, not 以下, at the end: 请大家注意一下. 以下 ends a clause only after a number or a unit
    (十岁以下), which keep it.
  * 再, not 在, between a word of time or need and a verb: 下周再讨论, 能不能再优化一下,
    颜色可以再亮一点. After those words 在 would need a place, so anything that isn't clearly a
    verb (明天在家, 需要在测试环境) keeps 在, and so does a verb used as a noun (讨论区, 讨论之前).

Only a sentence the sentence maker assembled is touched, never a dictionary word or one the user
has typed before. The fixed sentence comes first and the original right after it. The fixed one
is a plain candidate, so committing it doesn't teach the user dictionary the original.
--]]

local function set(list)
    local t = {}
    for _, w in ipairs(list) do t[w] = true end
    return t
end

local function chars(s)
    local t = {}
    for _, code in utf8.codes(s) do t[#t + 1] = utf8.char(code) end
    return t
end

local function starts(t, i, word)  -- does the character list t read `word` from position i?
    local w = chars(word)
    for k = 1, #w do
        if t[i + k - 1] ~= w[k] then return false end
    end
    return true
end

local function ends(t, i, word)  -- ... ending at position i?
    local w = chars(word)
    if i - #w + 1 < 1 then return false end
    return starts(t, i - #w + 1, word)
end

local function any_start(t, i, words)
    for _, w in ipairs(words) do
        if starts(t, i, w) then return w end
    end
end

local function any_end(t, i, words)
    for _, w in ipairs(words) do
        if ends(t, i, w) then return w end
    end
end

-- 吧 ------------------------------------------------------------------------------------------
local BA_KEEP = set { "一", "这", "那", "哪", "几", "两", "每", "火", "拖", "刀", "车", "门", "扶", "枪",
    "扳", "锁", "掌", "半", "整" }

local function fix_ba(t)
    local n = #t
    if n >= 2 and t[n] == "把" and not BA_KEEP[t[n - 1]] then
        t[n] = "吧"
        return true
    end
end

-- 一下 ----------------------------------------------------------------------------------------
local YIXIA_KEEP = set { "零", "〇", "一", "二", "三", "两", "四", "五", "六", "七", "八", "九", "十", "百",
    "千", "万", "亿", "岁", "度", "元", "块", "米", "斤", "分", "级", "层", "楼", "及", "如", "于", "在", "个",
    "人", "次", "年", "月", "天", "克", "秒", "名", "位", "倍", "折", "成" }

local function fix_yixia(t)
    local n = #t
    if n >= 3 and t[n - 1] == "以" and t[n] == "下" and not YIXIA_KEEP[t[n - 2]]
        and not t[n - 2]:match("^%d$") then
        t[n - 1] = "一"
        return true
    end
end

-- 再 ------------------------------------------------------------------------------------------
-- Words of time or need right before it: 再 is "again, then"; 在 would need a place after.
local TRIGGERS = { "可不可以", "要不要", "能不能", "到时候", "等会儿", "待会儿", "一会儿", "需要", "可以",
    "能否", "不能", "还能", "还要", "还得", "还想", "我要", "你要", "就要", "我想", "你想", "下周", "下次", "下回",
    "明天", "后天", "改天", "回头", "以后", "然后", "之后", "稍后", "晚点", "等会", "待会", "一会", "不要", "不用",
    "最好", "必须" }
-- 别 and 先 alone, except as the end of 特别, 首先 and the like.
local SHORT_TRIGGERS = { ["别"] = set { "特", "区", "分", "告", "识", "级", "性", "类", "派", "个", "辨", "鉴", "差",
    "离", "判", "惜", "送", "永" },
    ["先"] = set { "首", "原", "事", "预", "祖", "优", "领", "率", "争", "抢", "早" } }

local function trigger_before(t, i)  -- does a trigger end at position i?
    if any_end(t, i, TRIGGERS) then return true end
    local not_after = SHORT_TRIGGERS[t[i]]
    return not_after ~= nil and not not_after[t[i - 1] or ""]
end
-- Verbs that are always verbs after it (anything may follow).
local VERBS = { "看一下", "看一遍", "想一下", "试一下", "试一次", "问一下", "改一下", "等一下", "测一下",
    "测试一下", "讨论", "确认", "检查", "核对", "优化", "修改", "调整", "补充", "申请", "提交", "联系", "沟通",
    "考虑", "商量", "研究", "坚持", "努力", "回来", "过来", "重新", "看看", "想想", "试试", "问问", "改改",
    "等等", "仔细", "详细" }
-- ... unless a noun-making word follows: 讨论区, 讨论之前.
local NOUNISH = { "之前", "之后", "以前", "以后", "期间", "过程", "阶段", "结果", "方案", "文档", "环节", "前",
    "后", "中", "时", "的", "区", "会", "组", "室", "上", "里", "稿", "版", "群", "者" }
-- One-character verbs, often the start of a longer word (说明书), so only before these.
local SHORT_VERBS = set { "说", "聊", "来", "发", "约", "加", "做", "弄", "跑", "测", "见", "吃", "喝", "买",
    "等", "看", "想", "试", "问", "改" }
local SHORT_NEXT = { "一下", "一遍", "一次", "一会", "吧", "了", "呢", "啊", "呗", "几", "点", "个", "些", "我",
    "你", "他", "她", "这", "那", "上" }
-- Adjectives, before 一点 / 一些: 再亮一点.
local ADJECTIVES = set { "多", "少", "亮", "暗", "大", "小", "快", "慢", "高", "低", "早", "晚", "长", "短",
    "简单", "详细", "具体", "便宜", "清楚", "近", "远", "深", "浅", "宽", "窄", "轻", "重", "细", "粗" }
local MORE = { "一点", "一些", "点", "些" }

local function verb_follows(t, i)  -- t[i] is the first character after 在
    local v = any_start(t, i, VERBS)
    if v then
        return not any_start(t, i + #chars(v), NOUNISH)
    end
    if SHORT_VERBS[t[i]] then
        return i == #t or any_start(t, i + 1, SHORT_NEXT) ~= nil
    end
    for len = 2, 1, -1 do
        local adj = table.concat(t, "", i, math.min(#t, i + len - 1))
        if #chars(adj) == len and ADJECTIVES[adj] and any_start(t, i + len, MORE) then return true end
    end
    return false
end

local function fix_zai(t)
    local changed = false
    for i = 2, #t - 1 do
        if t[i] == "在" and trigger_before(t, i - 1) and verb_follows(t, i + 1) then
            t[i] = "再"
            changed = true
        end
    end
    return changed
end

-- -----------------------------------------------------------------------------------------------
local function fixed(text)
    local t = chars(text)
    local a, b, c = fix_zai(t), fix_ba(t), fix_yixia(t)
    if a or b or c then return table.concat(t) end
end

local function filter(input)
    local first, extra = true, nil
    for cand in input:iter() do
        if first then
            first = false
            local text = cand.type == "sentence" and fixed(cand.text)
            if text then
                local c = Candidate("sentence", cand.start, cand._end, text, cand.comment)
                c.preedit = cand.preedit
                c.quality = cand.quality
                extra = text
                yield(c)
            end
            yield(cand)
        elseif cand.text ~= extra then
            yield(cand)
        end
    end
end

return filter
