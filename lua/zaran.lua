local Module = {}

---双拼 → 拼音 反向映射表（由 zrmify 的 ALL_PINYIN 生成，401 键；eg 为手动补 eng）
Module.zrm_map = {
    ["aa"] = "a", ["ah"] = "ang", ["ai"] = "ai", ["an"] = "an", ["ao"] = "ao", ["ba"] = "ba", ["bc"] = "biao", ["bf"] = "ben", ["bg"] = "beng", ["bh"] = "bang", ["bi"] = "bi", ["bj"] = "ban",
    ["bk"] = "bao", ["bl"] = "bai", ["bm"] = "bian", ["bn"] = "bin", ["bo"] = "bo", ["bu"] = "bu", ["bx"] = "bie", ["by"] = "bing", ["bz"] = "bei", ["ca"] = "ca", ["cb"] = "cou", ["ce"] = "ce",
    ["cf"] = "cen", ["cg"] = "ceng", ["ch"] = "cang", ["ci"] = "ci", ["cj"] = "can", ["ck"] = "cao", ["cl"] = "cai", ["co"] = "cuo", ["cp"] = "cun", ["cr"] = "cuan", ["cs"] = "cong", ["cu"] = "cu",
    ["cv"] = "cui", ["da"] = "da", ["db"] = "dou", ["dc"] = "diao", ["de"] = "de", ["dg"] = "deng", ["dh"] = "dang", ["di"] = "di", ["dj"] = "dan", ["dk"] = "dao", ["dl"] = "dai", ["dm"] = "dian",
    ["do"] = "duo", ["dp"] = "dun", ["dq"] = "diu", ["dr"] = "duan", ["ds"] = "dong", ["du"] = "du", ["dv"] = "dui", ["dx"] = "die", ["dy"] = "ding", ["ee"] = "e", ["eg"] = "eng", ["ei"] = "ei", ["en"] = "en",
    ["er"] = "er", ["fa"] = "fa", ["fb"] = "fou", ["ff"] = "fen", ["fg"] = "feng", ["fh"] = "fang", ["fj"] = "fan", ["fo"] = "fo", ["fu"] = "fu", ["fz"] = "fei", ["ga"] = "ga", ["gb"] = "gou",
    ["gd"] = "guang", ["ge"] = "ge", ["gf"] = "gen", ["gg"] = "geng", ["gh"] = "gang", ["gj"] = "gan", ["gk"] = "gao", ["gl"] = "gai", ["go"] = "guo", ["gp"] = "gun", ["gr"] = "guan", ["gs"] = "gong",
    ["gu"] = "gu", ["gv"] = "gui", ["gw"] = "gua", ["gy"] = "guai", ["gz"] = "gei", ["ha"] = "ha", ["hb"] = "hou", ["hd"] = "huang", ["he"] = "he", ["hf"] = "hen", ["hg"] = "heng", ["hh"] = "hang",
    ["hj"] = "han", ["hk"] = "hao", ["hl"] = "hai", ["ho"] = "huo", ["hp"] = "hun", ["hr"] = "huan", ["hs"] = "hong", ["hu"] = "hu", ["hv"] = "hui", ["hw"] = "hua", ["hy"] = "huai", ["hz"] = "hei",
    ["ia"] = "cha", ["ib"] = "chou", ["id"] = "chuang", ["ie"] = "che", ["if"] = "chen", ["ig"] = "cheng", ["ih"] = "chang", ["ii"] = "chi", ["ij"] = "chan", ["ik"] = "chao", ["il"] = "chai", ["io"] = "chuo",
    ["ip"] = "chun", ["ir"] = "chuan", ["is"] = "chong", ["iu"] = "chu", ["iv"] = "chui", ["iy"] = "chuai", ["jc"] = "jiao", ["jd"] = "jiang", ["ji"] = "ji", ["jm"] = "jian", ["jn"] = "jin", ["jp"] = "jun",
    ["jq"] = "jiu", ["jr"] = "juan", ["js"] = "jiong", ["jt"] = "jue", ["ju"] = "ju", ["jw"] = "jia", ["jx"] = "jie", ["jy"] = "jing", ["ka"] = "ka", ["kb"] = "kou", ["kd"] = "kuang", ["ke"] = "ke",
    ["kf"] = "ken", ["kg"] = "keng", ["kh"] = "kang", ["kj"] = "kan", ["kk"] = "kao", ["kl"] = "kai", ["ko"] = "kuo", ["kp"] = "kun", ["kr"] = "kuan", ["ks"] = "kong", ["ku"] = "ku", ["kv"] = "kui",
    ["kw"] = "kua", ["ky"] = "kuai", ["la"] = "la", ["lb"] = "lou", ["lc"] = "liao", ["ld"] = "liang", ["le"] = "le", ["lg"] = "leng", ["lh"] = "lang", ["li"] = "li", ["lj"] = "lan", ["lk"] = "lao",
    ["ll"] = "lai", ["lm"] = "lian", ["ln"] = "lin", ["lo"] = "luo", ["lp"] = "lun", ["lq"] = "liu", ["lr"] = "luan", ["ls"] = "long", ["lt"] = "lüe", ["lu"] = "lu", ["lv"] = "lü", ["lw"] = "lia",
    ["lx"] = "lie", ["ly"] = "ling", ["lz"] = "lei", ["ma"] = "ma", ["mb"] = "mou", ["mc"] = "miao", ["me"] = "me", ["mf"] = "men", ["mg"] = "meng", ["mh"] = "mang", ["mi"] = "mi", ["mj"] = "man",
    ["mk"] = "mao", ["ml"] = "mai", ["mm"] = "mian", ["mn"] = "min", ["mo"] = "mo", ["mq"] = "miu", ["mu"] = "mu", ["mx"] = "mie", ["my"] = "ming", ["mz"] = "mei", ["na"] = "na", ["nb"] = "nou",
    ["nc"] = "niao", ["nd"] = "niang", ["ne"] = "ne", ["nf"] = "nen", ["ng"] = "neng", ["nh"] = "nang", ["ni"] = "ni", ["nj"] = "nan", ["nk"] = "nao", ["nl"] = "nai", ["nm"] = "nian", ["nn"] = "nin",
    ["no"] = "nuo", ["nq"] = "niu", ["nr"] = "nuan", ["ns"] = "nong", ["nt"] = "nüe", ["nu"] = "nu", ["nv"] = "nü", ["nx"] = "nie", ["ny"] = "ning", ["nz"] = "nei", ["oo"] = "o", ["ou"] = "ou",
    ["pa"] = "pa", ["pb"] = "pou", ["pc"] = "piao", ["pf"] = "pen", ["pg"] = "peng", ["ph"] = "pang", ["pi"] = "pi", ["pj"] = "pan", ["pk"] = "pao", ["pl"] = "pai", ["pm"] = "pian", ["pn"] = "pin",
    ["po"] = "po", ["pu"] = "pu", ["px"] = "pie", ["py"] = "ping", ["pz"] = "pei", ["qc"] = "qiao", ["qd"] = "qiang", ["qi"] = "qi", ["qm"] = "qian", ["qn"] = "qin", ["qp"] = "qun", ["qq"] = "qiu",
    ["qr"] = "quan", ["qs"] = "qiong", ["qt"] = "que", ["qu"] = "qu", ["qw"] = "qia", ["qx"] = "qie", ["qy"] = "qing", ["rb"] = "rou", ["re"] = "re", ["rf"] = "ren", ["rg"] = "reng", ["rh"] = "rang",
    ["ri"] = "ri", ["rj"] = "ran", ["rk"] = "rao", ["ro"] = "ruo", ["rp"] = "run", ["rr"] = "ruan", ["rs"] = "rong", ["ru"] = "ru", ["rv"] = "rui", ["sa"] = "sa", ["sb"] = "sou", ["se"] = "se",
    ["sf"] = "sen", ["sg"] = "seng", ["sh"] = "sang", ["si"] = "si", ["sj"] = "san", ["sk"] = "sao", ["sl"] = "sai", ["so"] = "suo", ["sp"] = "sun", ["sr"] = "suan", ["ss"] = "song", ["su"] = "su",
    ["sv"] = "sui", ["ta"] = "ta", ["tb"] = "tou", ["tc"] = "tiao", ["te"] = "te", ["tg"] = "teng", ["th"] = "tang", ["ti"] = "ti", ["tj"] = "tan", ["tk"] = "tao", ["tl"] = "tai", ["tm"] = "tian",
    ["to"] = "tuo", ["tp"] = "tun", ["tr"] = "tuan", ["ts"] = "tong", ["tu"] = "tu", ["tv"] = "tui", ["tx"] = "tie", ["ty"] = "ting", ["ua"] = "sha", ["ub"] = "shou", ["ud"] = "shuang", ["ue"] = "she",
    ["uf"] = "shen", ["ug"] = "sheng", ["uh"] = "shang", ["ui"] = "shi", ["uj"] = "shan", ["uk"] = "shao", ["ul"] = "shai", ["uo"] = "shuo", ["up"] = "shun", ["ur"] = "shuan", ["uu"] = "shu", ["uv"] = "shui",
    ["uw"] = "shua", ["uy"] = "shuai", ["va"] = "zha", ["vb"] = "zhou", ["vd"] = "zhuang", ["ve"] = "zhe", ["vf"] = "zhen", ["vg"] = "zheng", ["vh"] = "zhang", ["vi"] = "zhi", ["vj"] = "zhan", ["vk"] = "zhao",
    ["vl"] = "zhai", ["vo"] = "zhuo", ["vp"] = "zhun", ["vr"] = "zhuan", ["vs"] = "zhong", ["vu"] = "zhu", ["vv"] = "zhui", ["vw"] = "zhua", ["vy"] = "zhuai", ["wa"] = "wa", ["wf"] = "wen", ["wg"] = "weng",
    ["wh"] = "wang", ["wj"] = "wan", ["wl"] = "wai", ["wo"] = "wo", ["wu"] = "wu", ["wz"] = "wei", ["xc"] = "xiao", ["xd"] = "xiang", ["xi"] = "xi", ["xm"] = "xian", ["xn"] = "xin", ["xp"] = "xun",
    ["xq"] = "xiu", ["xr"] = "xuan", ["xs"] = "xiong", ["xt"] = "xue", ["xu"] = "xu", ["xw"] = "xia", ["xx"] = "xie", ["xy"] = "xing", ["ya"] = "ya", ["yb"] = "you", ["ye"] = "ye", ["yh"] = "yang",
    ["yi"] = "yi", ["yj"] = "yan", ["yk"] = "yao", ["yn"] = "yin", ["yo"] = "yo", ["yp"] = "yun", ["yr"] = "yuan", ["ys"] = "yong", ["yt"] = "yue", ["yu"] = "yu", ["yy"] = "ying", ["za"] = "za",
    ["zb"] = "zou", ["ze"] = "ze", ["zf"] = "zen", ["zg"] = "zeng", ["zh"] = "zang", ["zi"] = "zi", ["zj"] = "zan", ["zk"] = "zao", ["zl"] = "zai", ["zo"] = "zuo", ["zp"] = "zun", ["zr"] = "zuan",
    ["zs"] = "zong", ["zu"] = "zu", ["zv"] = "zui", ["zz"] = "zei",
}

---A more robust io.open
---@param rel_path string a relative path
function Module.open_rime_file(rel_path, pathsep)
    -- Case 1: user dir
    local path = rime_api.get_user_data_dir() .. pathsep .. rel_path
    local file, err = io.open(path)
    if file then
        return file
    else
        log.error('加载失败：' .. path .. ',错误原因: ' .. err)
    end
    
    -- Case 2: shared dir
    if pathsep == '\\' then
        return nil
    end
    local prefixes = {
        '/usr/local/share/rime-data/',
        '/usr/share/rime-data/'
    }
    for _, prefix in pairs(prefixes) do
        path = prefix .. rel_path
        file, err = io.open(path)
        if file then
            return file
        else
            log.error('加载失败：' .. path .. ',错误原因: ' .. err)
        end
    end
    return nil
end

---Load cuoyin.pro.dict.yaml bundled with the standard Moran distribution.
---@return table<integer,table<string>>
function Module.load_cuoyin()
    if Module.corrections_cache then
        return Module.corrections_cache
    end
    local auto_delimiter = " "
    local pathsep = (package.config or '/'):sub(1, 1)
    local file = Module.open_rime_file('dicts' .. pathsep .. 'cuoyin.pro.dict.yaml', pathsep)
    if not file then
        log.error('无法打开cuoyin.pro.dict.yaml')
        return nil
    end
    local corrections_cache = {}
    for line in file:lines() do
        if not line:match("^#") then
            local text, code, weight, comment = line:match("^(.-)\t(.-)\t(.-)\t(.-)$")
            if text and code then
                text = text:match("^%s*(.-)%s*$")
                code = code:match("^%s*(.-)%s*$")
                comment = comment and comment:match("^%s*(.-)%s*$") or ""
                comment = comment:gsub("%s+", auto_delimiter)
                code = code:gsub("%s+", auto_delimiter)
                corrections_cache[code] = { text = text, comment = comment }
            end
        end
    end
    file:close()
    Module.corrections_cache = corrections_cache
    return Module.corrections_cache
end

---判断是否在命令模式
---@param context Context | nil
---@return boolean
function Module.is_function_mode_active(context)
    if not context or not context.composition or context.composition:empty() then
        return false
    end

    local seg = context.composition:back()
    if not seg then return false end

    return seg:has_tag("number")
        or seg:has_tag("unicode")
        or seg:has_tag("calculator")
        or seg:has_tag("shijian")
        or seg:has_tag("Ndate")
        or seg:has_tag("kagiroi")
        or seg:has_tag("mixed_V")
        or seg:has_tag("date_offset")
end

function Module.segment_is_reverse_lookup(seg)
    if seg:has_tag("kagiroi") then
        return true
    end

    -- 所有反查都不過濾：
    for tag, _ in pairs(seg.tags) do
        if tag:match("^reverse_") then
            return true
        end
    end
    return false
end

function Module.is_reverse_lookup(env)
    local seg = env.engine.context.composition:back()
    if not seg then
        return false
    end
    return Module.segment_is_reverse_lookup(seg)
end

function Module.Thunk(functor)
    local result = nil
    return function()
        if result == nil then
            result = functor()
        end
        return result
    end
end

return Module