--[[
Luma: tells the app which candidates the sentence maker assembled from pieces.

A candidate of type "sentence" is Rime's guess at a phrase it has no entry for; a dictionary
word or one the user has typed before has another type. This filter prefixes the comment of
sentences with "\2", which the app strips and uses to rank AI suggestions: an assembled first
choice gives way to a suggestion, a known word keeps first place. It runs last, so every other
filter has already had its say.
--]]

local function filter(input)
    for cand in input:iter() do
        if cand.type == "sentence" then
            yield(ShadowCandidate(cand, cand.type, cand.text, "\2" .. cand.comment))
        else
            yield(cand)
        end
    end
end

return filter
