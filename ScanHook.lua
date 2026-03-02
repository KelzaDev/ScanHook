--[[
  SCAN & HOOK v3.7 — clean rewrite
  - Toàn bộ wrapped trong pcall để không crash
  - Không dùng Enum.KeyCode trực tiếp
  - UIS optional (graceful fallback)
  - SimpleSpy-style Hook tab
  - Tab Config: hotkey, path, depth, window, colors
]]

-- ================================================================
-- SERVICES (tất cả qua pcall)
-- ================================================================
local ok_,Players_  = pcall(function() return game:GetService("Players") end)
local ok2,RS_       = pcall(function() return game:GetService("ReplicatedStorage") end)
local ok3,WS_       = pcall(function() return game:GetService("Workspace") end)

local Players = ok_ and Players_ or nil
local RS      = ok2 and RS_      or nil
local WS      = ok3 and WS_      or nil
local LP      = Players and Players.LocalPlayer or nil

local UIS     = nil
pcall(function() UIS = game:GetService("UserInputService") end)

if not Players or not RS or not WS or not LP then
    warn("[SHT] Missing core services")
    return
end

-- ================================================================
-- CONFIG
-- ================================================================
local CFG = {
    hotkeyToggle   = "RightControl",
    hotkeyHookFire = "F8",
    eventsPath     = "events",
    scanDepthRS    = 6,
    scanDepthWS    = 4,
    maxCalls       = 300,
    winW           = 880,
    winH           = 580,
}

-- ================================================================
-- STATE
-- ================================================================
local hookFire, hookInvoke, hookDebug = false, false, false
local namecallInstalled, oldNamecall  = false, nil
local hookQueue    = {}
local remoteCache  = {}
local remCfg, remFreq, remLastArgs = {}, {}, {}
local clientConns, clientLastLog   = {}, {}
local knownR, pendingR = {}, {}
local decompiledSource, diffSnap, scriptCache = "", nil, {}
local spActive, spCnt, multiActive = false, 0, false
local sLogBuf = {}
local callLog  = {}
local selCall  = nil
local excludeSet = {}

-- ================================================================
-- HELPERS
-- ================================================================
local function cfg(n)  if not remCfg[n]  then remCfg[n]={block=false,mod=nil,filt=nil} end; return remCfg[n]  end
local function freq(n) if not remFreq[n] then remFreq[n]={c=0,t=tick(),r=0}            end; return remFreq[n] end
local function bump(n) local f=freq(n); f.c=f.c+1; local e=tick()-f.t; if e>=1 then f.r=math.floor(f.c/e*10)/10; f.c=0; f.t=tick() end end
local function a2s(t)
    if not t then return "" end
    local p={}
    for _,v in ipairs(t) do
        if type(v)=="string" then p[#p+1]='"'..v..'"'
        else p[#p+1]=tostring(v) end
    end
    return table.concat(p,",")
end
local function parseA(s)
    if not s or s=="" then return {} end
    local o={}
    for p in s:gmatch("[^,]+") do
        local v=p:match("^%s*(.-)%s*$")
        local n=tonumber(v)
        if n then o[#o+1]=n
        elseif v=="true" then o[#o+1]=true
        elseif v=="false" then o[#o+1]=false
        else o[#o+1]=v:match('^["\'](.+)["\']$') or v end
    end
    return o
end
local function ensureR(n)
    if not n or n=="" or n=="?" or knownR[n] then return end
    knownR[n]=true; pendingR[#pendingR+1]=n
end

-- ================================================================
-- REMOTE CACHE  (buildRemoteCache chạy NGOÀI __namecall → IsA an toàn)
-- ================================================================
local function buildRemoteCache()
    remoteCache = {}
    local function scan(folder, depth)
        if depth > 6 then return end
        pcall(function()
            for _,r in ipairs(folder:GetChildren()) do
                local isRE,isRF = false,false
                pcall(function() isRE = r:IsA("RemoteEvent")   end)
                pcall(function() if not isRE then isRF = r:IsA("RemoteFunction") end end)
                if isRE or isRF then
                    local nm=""; pcall(function() nm=r.Name end)
                    remoteCache[r]={isRE=isRE,isRF=isRF,nm=nm}
                end
                local ok,ch = pcall(function() return r:GetChildren() end)
                if ok and ch and #ch>0 then scan(r,depth+1) end
            end
        end)
    end
    pcall(function() scan(RS,0) end)
    pcall(function() scan(WS,0) end)
end

-- ================================================================
-- COLORS
-- ================================================================
local BG   = Color3.fromRGB(10,10,16)
local BG1  = Color3.fromRGB(16,16,24)
local BG2  = Color3.fromRGB(22,22,34)
local BG3  = Color3.fromRGB(28,28,44)
local TXT  = Color3.fromRGB(220,225,255)
local TXT1 = Color3.fromRGB(140,145,180)
local TXT2 = Color3.fromRGB(70,73,110)
local LINE = Color3.fromRGB(35,35,55)
local BLUE = Color3.fromRGB(70,145,255)
local PURP = Color3.fromRGB(145,70,255)
local GREEN= Color3.fromRGB(70,215,135)
local RED  = Color3.fromRGB(215,65,65)
local AMBER= Color3.fromRGB(235,170,50)
local CYAN = Color3.fromRGB(50,205,200)
local TACC = {Scan=BLUE,Hook=PURP,Spam=RED,Decompile=CYAN,Players=AMBER,Executor=GREEN,Config=Color3.fromRGB(55,55,70)}

-- ================================================================
-- GUI ROOT
-- ================================================================
local SG = Instance.new("ScreenGui")
SG.Name = "SHT37"; SG.ResetOnSpawn = false
SG.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
if not pcall(function() SG.Parent = game:GetService("CoreGui") end) then
    if not pcall(function() SG.Parent = gethui() end) then
        SG.Parent = LP.PlayerGui
    end
end

local WIN = Instance.new("Frame", SG)
WIN.Size     = UDim2.new(0, CFG.winW, 0, CFG.winH)
WIN.Position = UDim2.new(0.5, -CFG.winW/2, 0.5, -CFG.winH/2)
WIN.BackgroundColor3 = BG; WIN.BorderSizePixel = 0
WIN.Active = true; WIN.Draggable = true
Instance.new("UICorner",WIN).CornerRadius = UDim.new(0,10)

-- Title bar
local TBar = Instance.new("Frame",WIN)
TBar.Size=UDim2.new(1,0,0,40); TBar.BackgroundColor3=BG1; TBar.BorderSizePixel=0
Instance.new("UICorner",TBar).CornerRadius=UDim.new(0,10)
local TBarFix=Instance.new("Frame",TBar)
TBarFix.Size=UDim2.new(1,0,0.5,0); TBarFix.Position=UDim2.new(0,0,0.5,0)
TBarFix.BackgroundColor3=BG1; TBarFix.BorderSizePixel=0

local titleL=Instance.new("TextLabel",TBar)
titleL.Text="SCAN & HOOK  v3.7"; titleL.Size=UDim2.new(0,200,1,0)
titleL.Position=UDim2.new(0,12,0,0); titleL.BackgroundTransparency=1
titleL.TextColor3=TXT; titleL.Font=Enum.Font.GothamBold; titleL.TextSize=13
titleL.TextXAlignment=Enum.TextXAlignment.Left; titleL.RichText=false

local hkHint=Instance.new("TextLabel",TBar)
hkHint.Size=UDim2.new(0,140,0,16); hkHint.Position=UDim2.new(0,210,0.5,-8)
hkHint.BackgroundTransparency=1; hkHint.TextColor3=TXT2
hkHint.Font=Enum.Font.Gotham; hkHint.TextSize=9
hkHint.TextXAlignment=Enum.TextXAlignment.Left; hkHint.RichText=false
hkHint.Text="["..CFG.hotkeyToggle.."] toggle"

local stBar=Instance.new("TextLabel",TBar)
stBar.Size=UDim2.new(0,250,0,20); stBar.Position=UDim2.new(1,-344,0.5,-10)
stBar.BackgroundColor3=BG2; stBar.BorderSizePixel=0; stBar.TextColor3=TXT1
stBar.Font=Enum.Font.Gotham; stBar.TextSize=10; stBar.Text="Ready"
stBar.TextXAlignment=Enum.TextXAlignment.Left; stBar.RichText=false
Instance.new("UICorner",stBar).CornerRadius=UDim.new(0,10)
local _sp=Instance.new("UIPadding",stBar); _sp.PaddingLeft=UDim.new(0,8)

local xBtn=Instance.new("TextButton",TBar)
xBtn.Text="X"; xBtn.Size=UDim2.new(0,28,0,28); xBtn.Position=UDim2.new(1,-34,0.5,-14)
xBtn.BackgroundColor3=Color3.fromRGB(170,38,38); xBtn.TextColor3=TXT
xBtn.Font=Enum.Font.GothamBold; xBtn.TextSize=12; xBtn.BorderSizePixel=0; xBtn.RichText=false
Instance.new("UICorner",xBtn).CornerRadius=UDim.new(0,6)
xBtn.MouseButton1Click:Connect(function() SG:Destroy() end)

local function setSt(m) pcall(function() stBar.Text=tostring(m) end) end

-- Tab bar + content
local TABS_BAR=Instance.new("Frame",WIN)
TABS_BAR.Size=UDim2.new(1,-16,0,28); TABS_BAR.Position=UDim2.new(0,8,0,44)
TABS_BAR.BackgroundTransparency=1
local tbl=Instance.new("UIListLayout",TABS_BAR)
tbl.FillDirection=Enum.FillDirection.Horizontal; tbl.Padding=UDim.new(0,4)

local CONT=Instance.new("Frame",WIN)
CONT.Size=UDim2.new(1,-16,1,-86); CONT.Position=UDim2.new(0,8,0,76)
CONT.BackgroundColor3=BG1; CONT.BorderSizePixel=0
Instance.new("UICorner",CONT).CornerRadius=UDim.new(0,8)

-- ================================================================
-- HOTKEY (safe - no crash if UIS unavailable)
-- ================================================================
local guiVisible = true
local function toggleGUI()
    guiVisible = not guiVisible
    pcall(function() WIN.Visible = guiVisible end)
    setSt(guiVisible and "Ready" or "Hidden ["..CFG.hotkeyToggle.."]")
end

if UIS then
    pcall(function()
        UIS.InputBegan:Connect(function(inp, gp)
            if gp then return end
            pcall(function()
                if inp.UserInputType ~= Enum.UserInputType.Keyboard then return end
                local kn = tostring(inp.KeyCode.Name)
                if kn == CFG.hotkeyToggle then
                    toggleGUI()
                elseif kn == CFG.hotkeyHookFire then
                    -- toggle hookFire directly instead of :Fire()
                    pcall(function()
                        hookFire = not hookFire
                        if hookFire then installNC() end
                        if not hookFire and not hookInvoke and not hookDebug then removeNC() end
                    end)
                end
            end)
        end)
    end)
end

-- ================================================================
-- WIDGET HELPERS
-- ================================================================
local function mkF(p,bg,sz,pos,r)
    local f=Instance.new("Frame",p)
    f.BackgroundColor3=bg or BG2; f.BorderSizePixel=0
    f.Size=sz or UDim2.new(1,0,1,0); f.Position=pos or UDim2.new(0,0,0,0)
    if r then Instance.new("UICorner",f).CornerRadius=UDim.new(0,r) end
    return f
end
local function mkL(p,t,sz,pos,c,fn,ts)
    local l=Instance.new("TextLabel",p)
    l.Text=t or ""; l.Size=sz or UDim2.new(1,0,0,14); l.Position=pos or UDim2.new(0,0,0,0)
    l.BackgroundTransparency=1; l.TextColor3=c or TXT1; l.Font=fn or Enum.Font.Gotham
    l.TextSize=ts or 11; l.TextXAlignment=Enum.TextXAlignment.Left
    l.TextWrapped=true; l.RichText=false
    return l
end
local function mkB(p,t,bg,sz,pos)
    local b=Instance.new("TextButton",p)
    b.Text=t; b.Size=sz or UDim2.new(0,70,0,24); b.Position=pos or UDim2.new(0,0,0,0)
    b.BackgroundColor3=bg or BG3; b.TextColor3=TXT; b.Font=Enum.Font.GothamBold
    b.TextSize=10; b.BorderSizePixel=0; b.RichText=false
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,5)
    return b
end
local function mkTB(p,ph,sz,pos,ml)
    local t=Instance.new("TextBox",p)
    t.PlaceholderText=ph or ""; t.Text=""
    t.Size=sz or UDim2.new(1,0,0,22); t.Position=pos or UDim2.new(0,0,0,0)
    t.BackgroundColor3=BG3; t.TextColor3=TXT; t.PlaceholderColor3=TXT2
    t.Font=Enum.Font.Code; t.TextSize=10; t.BorderSizePixel=0
    t.ClearTextOnFocus=false; t.TextXAlignment=Enum.TextXAlignment.Left
    t.MultiLine=ml or false; t.RichText=false
    Instance.new("UICorner",t).CornerRadius=UDim.new(0,5)
    local pd=Instance.new("UIPadding",t); pd.PaddingLeft=UDim.new(0,6)
    return t
end
local function mkSF(p,sz,pos)
    local s=Instance.new("ScrollingFrame",p)
    s.Size=sz or UDim2.new(1,0,1,0); s.Position=pos or UDim2.new(0,0,0,0)
    s.BackgroundTransparency=1; s.BorderSizePixel=0
    s.ScrollBarThickness=3; s.ScrollBarImageColor3=BLUE; s.CanvasSize=UDim2.new(0,0,0,0)
    return s
end
local function mkRow(p,y,h)
    local bar=mkF(p,BG,UDim2.new(1,-8,0,h),UDim2.new(0,4,0,y))
    bar.BackgroundTransparency=1
    local ll=Instance.new("UIListLayout",bar)
    ll.FillDirection=Enum.FillDirection.Horizontal; ll.Padding=UDim.new(0,4)
    ll.VerticalAlignment=Enum.VerticalAlignment.Center
    return function(t,bg)
        local b=mkB(bar,t,bg,UDim2.new(0,0,0,h-4))
        b.AutomaticSize=Enum.AutomaticSize.X
        local pd=Instance.new("UIPadding",b); pd.PaddingLeft=UDim.new(0,8); pd.PaddingRight=UDim.new(0,8)
        return b
    end
end

-- ================================================================
-- LOG WIDGET
-- ================================================================
local LINE_H    = 13
local CHUNK_SZ  = 300

local function mkLog(p,sz,pos)
    local bg = mkF(p,BG,sz,pos,7)
    local sf = mkSF(bg, UDim2.new(1,-4,1,-4), UDim2.new(0,2,0,2))
    local container = Instance.new("Frame",sf)
    container.BackgroundTransparency=1; container.BorderSizePixel=0
    container.Size=UDim2.new(1,0,0,0)

    local buf, chunkLabels = {}, {}
    local MAX = 5000

    local function makeLabel()
        local lbl=Instance.new("TextLabel",container)
        lbl.BackgroundTransparency=1; lbl.TextColor3=Color3.fromRGB(180,215,175)
        lbl.Font=Enum.Font.Code; lbl.TextSize=11
        lbl.TextXAlignment=Enum.TextXAlignment.Left; lbl.TextYAlignment=Enum.TextYAlignment.Top
        lbl.TextWrapped=true; lbl.RichText=false; lbl.Text=""
        return lbl
    end

    local api={}
    function api.add(t) buf[#buf+1]=tostring(t); if #buf>MAX then table.remove(buf,1) end end
    function api.flush()
        local total=#buf; if total==0 then return end
        local numC=math.ceil(total/CHUNK_SZ)
        while #chunkLabels<numC do chunkLabels[#chunkLabels+1]=makeLabel() end
        for i=numC+1,#chunkLabels do pcall(function() chunkLabels[i].Text="" end) end
        for ci=1,numC do
            local s=(ci-1)*CHUNK_SZ+1; local e=math.min(ci*CHUNK_SZ,total)
            local lines={}; for i=s,e do lines[#lines+1]=buf[i] end
            local h=(e-s+1)*LINE_H; local y=(ci-1)*CHUNK_SZ*LINE_H
            pcall(function()
                local lbl=chunkLabels[ci]
                lbl.Size=UDim2.new(1,-6,0,h+4); lbl.Position=UDim2.new(0,3,0,y+2)
                lbl.Text=table.concat(lines,"\n")
            end)
        end
        local totalH=total*LINE_H+12
        pcall(function()
            container.Size=UDim2.new(1,0,0,totalH)
            sf.CanvasSize=UDim2.new(0,0,0,totalH)
            sf.CanvasPosition=Vector2.new(0,totalH+9999)
        end)
    end
    function api.header(t) api.add(""); api.add("+-- "..t.." "..string.rep("-",math.max(0,32-#t))); api.flush() end
    function api.clear()
        buf={}
        for _,lbl in ipairs(chunkLabels) do pcall(function() lbl.Text="" end) end
        pcall(function()
            container.Size=UDim2.new(1,0,0,0); sf.CanvasSize=UDim2.new(0,0,0,0)
            sf.CanvasPosition=Vector2.new(0,0)
        end)
    end
    function api.copy() pcall(setclipboard, table.concat(buf,"\n")); setSt("Copied!") end
    function api.buf() return buf end
    return api
end

-- ================================================================
-- TAB SYSTEM
-- ================================================================
local tabs, pages, curTab = {}, {}, nil
local function mkTab(name)
    local b=Instance.new("TextButton",TABS_BAR)
    b.Text=name; b.Size=UDim2.new(0,0,1,0); b.AutomaticSize=Enum.AutomaticSize.X
    b.BackgroundColor3=BG2; b.TextColor3=TXT2; b.Font=Enum.Font.GothamBold
    b.TextSize=10; b.BorderSizePixel=0; b.RichText=false
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,5)
    local pd=Instance.new("UIPadding",b); pd.PaddingLeft=UDim.new(0,10); pd.PaddingRight=UDim.new(0,10)
    local pg=mkF(CONT,BG1,UDim2.new(1,0,1,0)); pg.Visible=false
    b.MouseButton1Click:Connect(function()
        if curTab then pcall(function() pages[curTab].Visible=false; tabs[curTab].BackgroundColor3=BG2; tabs[curTab].TextColor3=TXT2 end) end
        curTab=name; pcall(function() pg.Visible=true; b.BackgroundColor3=TACC[name] or BLUE; b.TextColor3=Color3.fromRGB(255,255,255); setSt(name) end)
    end)
    tabs[name]=b; pages[name]=pg
    return pg
end

-- ================================================================
-- TAB 1: SCAN
-- ================================================================
local sP    = mkTab("Scan")
local sRow  = mkRow(sP,4,26)
local bRS   = sRow("Scan RS",  Color3.fromRGB(18,50,105))
local bWS   = sRow("Scan WS",  Color3.fromRGB(18,68,42))
local bRem  = sRow("Remotes",  Color3.fromRGB(80,30,105))
local bUID  = sRow("UUIDs",    Color3.fromRGB(58,30,105))
local bPlt  = sRow("Plots",    Color3.fromRGB(68,55,12))
local bSnap = sRow("Snapshot", Color3.fromRGB(28,60,50))
local bDiff = sRow("Diff",     Color3.fromRGB(62,44,10))
local bJSON = sRow("JSON",     Color3.fromRGB(10,52,72))
local bCpS  = sRow("Copy",     Color3.fromRGB(12,55,55))
local bClS  = sRow("Clear",    Color3.fromRGB(50,10,10))

-- Toolbar2: Watch Sim + Search
local toolBar2 = mkF(sP,BG2,UDim2.new(1,-8,0,24),UDim2.new(0,4,0,34),5)
local simBtn   = mkB(toolBar2,"Watch Sim: OFF",Color3.fromRGB(26,26,44),UDim2.new(0,130,0,20),UDim2.new(0,3,0,2))
local simLbl   = mkL(toolBar2,"",UDim2.new(0,120,1,0),UDim2.new(0,136,0,0),GREEN,Enum.Font.GothamBold,10)
local sSearch  = mkTB(toolBar2,"search in log...",UDim2.new(1,-370,0,20),UDim2.new(0,262,0,2))
local sSrchBtn = mkB(toolBar2,"Find",Color3.fromRGB(22,50,90),UDim2.new(0,38,0,20),UDim2.new(1,-78,0,2))
local sSrchClr = mkB(toolBar2,"✕",Color3.fromRGB(50,20,20),UDim2.new(0,28,0,20),UDim2.new(1,-38,0,2))

local sLog = mkLog(sP,UDim2.new(1,-8,1,-66),UDim2.new(0,4,0,62))

-- Search
local function doSearch(kw)
    if kw=="" then return end; kw=kw:lower()
    local res={}
    for _,line in ipairs(sLogBuf) do
        if line:lower():find(kw,1,true) then res[#res+1]=line end
    end
    sLog.clear()
    if #res==0 then sLog.add("(no results for: "..kw..")") else
        sLog.add("[ "..kw.." | "..#res.." results ]")
        for _,l in ipairs(res) do sLog.add(l) end
    end
    sLog.flush(); setSt("Found: "..#res)
end
sSrchBtn.MouseButton1Click:Connect(function() doSearch(sSearch.Text:match("^%s*(.-)%s*$")) end)
sSearch.FocusLost:Connect(function(enter) if enter then doSearch(sSearch.Text:match("^%s*(.-)%s*$")) end end)
sSrchClr.MouseButton1Click:Connect(function()
    pcall(function() sSearch.Text="" end)
    sLog.clear()
    for _,l in ipairs(sLogBuf) do sLog.add(l) end
    sLog.flush(); setSt("Search cleared")
end)

-- Tree scanner
local function sTree(obj,d,max,buf,remOnly)
    if d>max then return end
    pcall(function()
        local ind=string.rep("  ",d)
        local cn=""; pcall(function() cn=obj.ClassName end)
        local nm=""; pcall(function() nm=obj.Name end)
        local isRem = cn=="RemoteEvent" or cn=="RemoteFunction"
        if remOnly then
            if isRem then buf[#buf+1]=ind.."["..cn.."] "..nm end
        else
            local line=ind.."["..cn.."] "..nm
            local _,isV=pcall(function() return obj:IsA("ValueBase") end)
            if isV then local _,v=pcall(function() return obj.Value end); if v~=nil then line=line..'="'..tostring(v)..'"' end end
            buf[#buf+1]=line
            local _,at=pcall(function() return obj:GetAttributes() end)
            if at then for k,v in pairs(at) do buf[#buf+1]=ind.."  ."..k.."="..tostring(v) end end
        end
        local _,ch=pcall(function() return obj:GetChildren() end)
        if ch then for _,c in ipairs(ch) do sTree(c,d+1,max,buf,remOnly) end end
    end)
end

local function runScan(obj,depth,label,remOnly)
    sLogBuf={}; sLog.clear(); sLog.header(label); setSt("Scanning "..label.."...")
    task.spawn(function()
        local buf={}
        pcall(function() sTree(obj,0,depth,buf,remOnly) end)
        local i=1
        while i<=#buf do
            for j=i,math.min(i+199,#buf) do sLog.add(buf[j]); sLogBuf[#sLogBuf+1]=buf[j] end
            sLog.flush(); i=i+200
            if i<=#buf then task.wait() end
        end
        sLog.flush(); setSt(label..": "..#buf.." lines")
    end)
end

bRS.MouseButton1Click:Connect(function() runScan(RS,CFG.scanDepthRS,"RS",false) end)
bWS.MouseButton1Click:Connect(function() runScan(WS,CFG.scanDepthWS,"WS",false) end)
bRem.MouseButton1Click:Connect(function()
    sLogBuf={}; sLog.clear(); sLog.header("Remotes"); setSt("Scanning remotes...")
    task.spawn(function()
        local buf={}
        pcall(function() sTree(RS,0,8,buf,true) end)
        pcall(function() sTree(WS,0,6,buf,true) end)
        local seen,deduped={},{}
        for _,l in ipairs(buf) do
            local n=l:match("%] (.+)$")
            if n and not seen[n] then seen[n]=true; deduped[#deduped+1]=l end
        end
        table.sort(deduped)
        for _,l in ipairs(deduped) do sLog.add(l); sLogBuf[#sLogBuf+1]=l end
        sLog.flush(); setSt("Remotes: "..#deduped)
    end)
end)
bUID.MouseButton1Click:Connect(function()
    sLog.clear(); sLog.header("UUID Scan"); setSt("Scanning...")
    task.spawn(function()
        local n,buf=0,{}
        local function s(obj,path,d)
            if d>8 then return end
            local nm=""; pcall(function() nm=obj.Name end)
            if #nm==36 and nm:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then buf[#buf+1]="  "..path; n=n+1 end
            pcall(function() for _,c in ipairs(obj:GetChildren()) do
                local cn=""; pcall(function() cn=c.Name end); s(c,path.."/"..cn,d+1)
            end end)
        end
        pcall(function() s(WS,"WS",0); s(RS,"RS",0) end)
        for _,l in ipairs(buf) do sLog.add(l) end; sLog.flush(); setSt("UUIDs: "..n)
    end)
end)
bPlt.MouseButton1Click:Connect(function()
    sLog.clear(); sLog.header("Plots"); setSt("...")
    task.spawn(function()
        local pl=WS:FindFirstChild("Plots")
        if not pl then sLog.add("Plots not found"); sLog.flush(); return end
        for _,p in ipairs(pl:GetChildren()) do
            sLog.add("[Plot] "..p.Name)
            pcall(function() for k,v in pairs(p:GetAttributes()) do sLog.add("  "..k.."="..tostring(v)) end end)
            pcall(function() for _,c in ipairs(p:GetChildren()) do
                local info="  ["..c.ClassName.."] "..c.Name
                if c.Name=="Sim" then local n2=0; for _,x in ipairs(c:GetChildren()) do if #x.Name==36 then n2=n2+1 end end; info=info.." ("..n2.." UUIDs)" end
                sLog.add(info)
            end end)
        end
        sLog.flush(); setSt("Plots done")
    end)
end)

local function snapObj(r)
    local s={}
    local function w(o,p)
        local cn=""; pcall(function() cn=o.ClassName end); s[p]=cn
        pcall(function() for k,v in pairs(o:GetAttributes()) do s[p.."@"..k]=tostring(v) end end)
        pcall(function() for _,c in ipairs(o:GetChildren()) do local nm=""; pcall(function() nm=c.Name end); w(c,p.."/"..nm) end end)
    end
    w(r,""); return s
end
bSnap.MouseButton1Click:Connect(function()
    task.spawn(function() diffSnap={ws=snapObj(WS),rs=snapObj(RS)}; sLog.add("[OK] Snapshot taken"); sLog.flush(); setSt("Snapshot OK") end)
end)
bDiff.MouseButton1Click:Connect(function()
    if not diffSnap then sLog.add("Take snapshot first"); sLog.flush(); return end
    sLog.clear(); sLog.header("Diff")
    task.spawn(function()
        local nowWS=snapObj(WS); local nowRS=snapObj(RS); local n=0
        local function diff(a,b,label)
            for k,v in pairs(b) do if not a[k] then sLog.add("[+] "..label.."/"..k.." ("..v..")"); n=n+1 end end
            for k,v in pairs(a) do if not b[k] then sLog.add("[-] "..label.."/"..k.." ("..v..")"); n=n+1 end end
        end
        diff(diffSnap.ws,nowWS,"WS"); diff(diffSnap.rs,nowRS,"RS")
        if n==0 then sLog.add("(no changes)") end
        sLog.flush(); setSt("Diff: "..n.." changes")
    end)
end)
bJSON.MouseButton1Click:Connect(function()
    sLog.clear(); sLog.header("JSON export"); setSt("Building...")
    task.spawn(function()
        local parts={}; local function addKV(k,v) parts[#parts+1]='"'..tostring(k)..'":"'..tostring(v)..'"' end
        local function j(o,depth)
            if depth>4 then return end
            pcall(function()
                local cn=""; pcall(function() cn=o.ClassName end)
                local nm=""; pcall(function() nm=o.Name end)
                addKV(nm,cn)
                pcall(function() for _,c in ipairs(o:GetChildren()) do j(c,depth+1) end end)
            end)
        end
        pcall(function() j(RS,0) end)
        local out="{"..table.concat(parts,",").."}"
        pcall(setclipboard,out); sLog.add("JSON copied to clipboard"); sLog.add("Size: "..#out.." chars"); sLog.flush(); setSt("JSON copied")
    end)
end)
bCpS.MouseButton1Click:Connect(function() sLog.copy() end)
bClS.MouseButton1Click:Connect(function() sLog.clear(); sLogBuf={} end)

-- Watch Sim
local simOn,simConn,simCnt2=false,nil,0
simBtn.MouseButton1Click:Connect(function()
    simOn=not simOn
    if simOn then
        pcall(function() simBtn.Text="Watch Sim: ON"; simBtn.BackgroundColor3=Color3.fromRGB(12,68,36) end)
        simCnt2=0
        task.spawn(function()
            local watched=nil
            while simOn do
                task.wait(2)
                pcall(function()
                    local pl=WS:FindFirstChild("Plots"); if not pl then return end
                    for _,p in ipairs(pl:GetChildren()) do
                        if tostring(p:GetAttribute("USERID"))==tostring(LP.UserId) then
                            local sim=p:FindFirstChild("Sim"); if not sim or sim==watched then return end
                            if simConn then simConn:Disconnect() end; watched=sim; simCnt2=0
                            for _,c in ipairs(sim:GetChildren()) do if #c.Name==36 then simCnt2=simCnt2+1 end end
                            simConn=sim.ChildAdded:Connect(function(child)
                                if #child.Name==36 and child.Name:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then
                                    simCnt2=simCnt2+1; pcall(function() simLbl.Text="UUIDs: "..simCnt2 end)
                                    sLog.add("[NEW UUID] "..child.Name); sLog.flush()
                                end
                            end)
                            pcall(function() simLbl.Text="Watching. UUIDs: "..simCnt2 end)
                        end
                    end
                end)
            end
            if simConn then pcall(function() simConn:Disconnect() end); simConn=nil end
        end)
    else
        pcall(function() simBtn.Text="Watch Sim: OFF"; simBtn.BackgroundColor3=Color3.fromRGB(26,26,44); simLbl.Text="" end)
        if simConn then pcall(function() simConn:Disconnect() end); simConn=nil end
        simOn=false
    end
end)

-- ================================================================
-- TAB 2: HOOK  (SimpleSpy style)
-- ================================================================
-- forward declare so buttons below can reference before definition
local installNC, removeNC
local hP = mkTab("Hook")
local hRow = mkRow(hP,4,28)
local hCli    = hRow("Watch Client",  Color3.fromRGB(90,30,30))
local hFire   = hRow("Hook Fire",     Color3.fromRGB(50,22,105))
local hInv    = hRow("Hook Invoke",   Color3.fromRGB(22,52,105))
local hStop   = hRow("Stop All",      Color3.fromRGB(72,16,16))
local hDbg    = hRow("Debug: OFF",    Color3.fromRGB(38,38,18))
local hTest   = hRow("Test",          Color3.fromRGB(18,58,38))
local hClrAll = hRow("Clear All",     Color3.fromRGB(50,10,10))

-- Left panel: call list
local leftW  = 0.30
local leftP  = mkF(hP,BG2,UDim2.new(leftW,-4,1,-40),UDim2.new(0,4,0,36),6)
local leftHdr= mkF(leftP,BG3,UDim2.new(1,0,0,26),UDim2.new(0,0,0,0),6)
mkF(leftHdr,BG3,UDim2.new(1,0,0.5,0),UDim2.new(0,0,0.5,0))
mkL(leftHdr,"CALLS",UDim2.new(0.5,0,1,0),UDim2.new(0,6,0,0),TXT1,Enum.Font.GothamBold,10)
local callCountL=mkL(leftHdr,"0",UDim2.new(0.5,0,1,0),UDim2.new(0.5,-6,0,0),GREEN,Enum.Font.GothamBold,10)
callCountL.TextXAlignment=Enum.TextXAlignment.Right
local callSF=mkSF(leftP,UDim2.new(1,-2,1,-26),UDim2.new(0,1,0,26))
local callLL=Instance.new("UIListLayout",callSF)
callLL.Padding=UDim.new(0,1); callLL.SortOrder=Enum.SortOrder.LayoutOrder

-- Right panel: code viewer
local rightP  = mkF(hP,BG,UDim2.new(1-leftW,-6,1,-40),UDim2.new(leftW,2,0,36),6)
local rightHdr= mkF(rightP,BG2,UDim2.new(1,0,0,26),UDim2.new(0,0,0,0),6)
mkF(rightHdr,BG2,UDim2.new(1,0,0.5,0),UDim2.new(0,0,0.5,0))
local codeTitle=mkL(rightHdr,"← click a call",UDim2.new(1,-90,1,0),UDim2.new(0,6,0,0),CYAN,Enum.Font.GothamBold,11)
local typeBadge=mkL(rightHdr,"",UDim2.new(0,60,0,16),UDim2.new(1,-65,0,5),AMBER,Enum.Font.GothamBold,9)
typeBadge.TextXAlignment=Enum.TextXAlignment.Center
Instance.new("UICorner",typeBadge).CornerRadius=UDim.new(0,4)
typeBadge.BackgroundColor3=BG3; typeBadge.BackgroundTransparency=0
local codeSF=mkSF(rightP,UDim2.new(1,-4,1,-90),UDim2.new(0,2,0,28))
local codeTxt=Instance.new("TextLabel",codeSF)
codeTxt.Size=UDim2.new(1,-6,0,9999); codeTxt.Position=UDim2.new(0,3,0,3)
codeTxt.BackgroundTransparency=1; codeTxt.TextColor3=Color3.fromRGB(180,225,175)
codeTxt.Font=Enum.Font.Code; codeTxt.TextSize=11
codeTxt.TextXAlignment=Enum.TextXAlignment.Left; codeTxt.TextYAlignment=Enum.TextYAlignment.Top
codeTxt.TextWrapped=true; codeTxt.RichText=false
codeTxt.Text="-- Select a call from the left"

-- Action buttons row 1
local btnBar=mkF(rightP,BG2,UDim2.new(1,-4,0,58),UDim2.new(0,2,1,-60),5)
local btnLL=Instance.new("UIListLayout",btnBar)
btnLL.FillDirection=Enum.FillDirection.Horizontal; btnLL.Padding=UDim.new(0,4)
btnLL.VerticalAlignment=Enum.VerticalAlignment.Center
local bPad=Instance.new("UIPadding",btnBar); bPad.PaddingLeft=UDim.new(0,6); bPad.PaddingTop=UDim.new(0,6)
local function abtn(lbl,bg)
    local b=mkB(btnBar,lbl,bg,UDim2.new(0,0,0,22)); b.AutomaticSize=Enum.AutomaticSize.X
    local p=Instance.new("UIPadding",b); p.PaddingLeft=UDim.new(0,8); p.PaddingRight=UDim.new(0,8)
    return b
end
local bCopyCode   = abtn("Copy Code",    Color3.fromRGB(12,55,55))
local bCopyRemote = abtn("Copy Remote",  Color3.fromRGB(12,44,72))
local bCopyArgs   = abtn("Copy Args",    Color3.fromRGB(14,46,38))
local bBlockBtn   = abtn("Block: OFF",   Color3.fromRGB(52,16,16))
local bRunCode    = abtn("Run Code",     Color3.fromRGB(20,68,30))

-- Action buttons row 2
local btnBar2=mkF(rightP,BG2,UDim2.new(1,-4,0,26),UDim2.new(0,2,1,-32),5)
local btnLL2=Instance.new("UIListLayout",btnBar2)
btnLL2.FillDirection=Enum.FillDirection.Horizontal; btnLL2.Padding=UDim.new(0,4)
btnLL2.VerticalAlignment=Enum.VerticalAlignment.Center
local bPad2=Instance.new("UIPadding",btnBar2); bPad2.PaddingLeft=UDim.new(0,6); bPad2.PaddingTop=UDim.new(0,3)
local function abtn2(lbl,bg)
    local b=mkB(btnBar2,lbl,bg,UDim2.new(0,0,0,20)); b.AutomaticSize=Enum.AutomaticSize.X
    local p=Instance.new("UIPadding",b); p.PaddingLeft=UDim.new(0,8); p.PaddingRight=UDim.new(0,8)
    return b
end
local bExclude  = abtn2("Exclude",   Color3.fromRGB(52,42,12))
local bClrMod   = abtn2("Clr Mod",   Color3.fromRGB(52,22,12))
local bClrCalls = abtn2("Clr Calls", Color3.fromRGB(50,10,10))
local bTest2    = abtn2("Test Hook", Color3.fromRGB(18,58,38))

-- Generate SimpleSpy-style code
local function genCode(entry)
    if not entry then return "-- no call selected" end
    local lines={}
    lines[#lines+1]="-- Script generated by SCAN & HOOK v3.7"
    lines[#lines+1]=""
    lines[#lines+1]="local args = {"
    for i,v in ipairs(entry.a) do
        local vs
        if type(v)=="string" then vs='"'..v..'"'
        elseif type(v)=="number" or type(v)=="boolean" then vs=tostring(v)
        else vs='--[['..type(v)..']] '..tostring(v) end
        lines[#lines+1]="    ["..i.."] = "..vs..","
    end
    lines[#lines+1]="}"
    lines[#lines+1]=""
    local evPath='game:GetService("ReplicatedStorage")'
    if CFG.eventsPath~="" then evPath=evPath.."."..CFG.eventsPath end
    local path=evPath.."."..entry.n
    if entry.t=="F" then lines[#lines+1]=path..":FireServer(table.unpack(args))"
    elseif entry.t=="I" then lines[#lines+1]=path..":InvokeServer(table.unpack(args))"
    else lines[#lines+1]="-- OnClientEvent: "..entry.n end
    return table.concat(lines,"\n")
end

local function showCall(entry)
    selCall=entry; if not entry then return end
    local code=genCode(entry)
    local n=0; for _ in code:gmatch("\n") do n=n+1 end; n=n+1
    local h=n*13+8
    pcall(function()
        codeTitle.Text=entry.n
        typeBadge.Text=entry.t=="F" and "FireServer" or entry.t=="I" and "InvokeServer" or "OnClient"
        typeBadge.BackgroundColor3=entry.t=="F" and PURP or entry.t=="I" and BLUE or GREEN
        codeTxt.Size=UDim2.new(1,-6,0,h); codeTxt.Text=code
        codeSF.CanvasSize=UDim2.new(0,0,0,h+6); codeSF.CanvasPosition=Vector2.new(0,0)
        local c2=cfg(entry.n)
        bBlockBtn.Text=c2.block and "Block: ON" or "Block: OFF"
        bBlockBtn.BackgroundColor3=c2.block and Color3.fromRGB(140,22,22) or Color3.fromRGB(52,16,16)
    end)
end

local function addCallItem(entry)
    if excludeSet[entry.n] then return end
    table.insert(callLog,1,entry)
    if #callLog>CFG.maxCalls then table.remove(callLog) end
    local icon=entry.t=="F" and "▶" or entry.t=="I" and "◆" or "◀"
    local iconClr=entry.t=="F" and PURP or entry.t=="I" and BLUE or GREEN
    local it=Instance.new("TextButton",callSF)
    it.Size=UDim2.new(1,0,0,28); it.BackgroundColor3=BG3; it.BorderSizePixel=0
    it.RichText=false; it.Text=""; it.LayoutOrder=0
    Instance.new("UICorner",it).CornerRadius=UDim.new(0,4)
    mkL(it,icon,UDim2.new(0,14,1,0),UDim2.new(0,4,0,0),iconClr,Enum.Font.GothamBold,11)
    mkL(it,entry.n,UDim2.new(1,-58,1,0),UDim2.new(0,20,0,0),TXT,Enum.Font.Gotham,10)
    local cntL=mkL(it,"#"..#entry.a,UDim2.new(0,28,0,16),UDim2.new(1,-32,0,6),TXT2,Enum.Font.GothamBold,9)
    cntL.TextXAlignment=Enum.TextXAlignment.Center
    Instance.new("UICorner",cntL).CornerRadius=UDim.new(0,3)
    cntL.BackgroundColor3=BG2; cntL.BackgroundTransparency=0
    for _,c in ipairs(callSF:GetChildren()) do
        if c:IsA("TextButton") then pcall(function() c.LayoutOrder=c.LayoutOrder+1 end) end
    end
    it.MouseButton1Click:Connect(function()
        for _,c in ipairs(callSF:GetChildren()) do
            if c:IsA("TextButton") then pcall(function() c.BackgroundColor3=BG3 end) end
        end
        it.BackgroundColor3=Color3.fromRGB(30,30,65); showCall(entry)
    end)
    local cnt=0
    for _,c in ipairs(callSF:GetChildren()) do if c:IsA("TextButton") then cnt=cnt+1 end end
    pcall(function()
        callSF.CanvasSize=UDim2.new(0,0,0,cnt*29+4)
        callSF.CanvasPosition=Vector2.new(0,0)
        callCountL.Text=tostring(cnt)
    end)
end

-- UI drain loop
task.spawn(function()
    while WIN.Parent do
        task.wait(0.15)
        if #hookQueue>0 then
            local batch=hookQueue; hookQueue={}
            for _,e in ipairs(batch) do
                pcall(function()
                    if e[1]=="F" or e[1]=="I" or e[1]=="C" then
                        addCallItem({n=e.n,t=e[1],a=e.a or {},ts=os.clock()})
                    end
                end)
            end
        end
    end
end)

-- Hook action buttons
bCopyCode.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    pcall(setclipboard,genCode(selCall)); setSt("Code copied!")
end)
bCopyRemote.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    local evPath='game:GetService("ReplicatedStorage")'
    if CFG.eventsPath~="" then evPath=evPath.."."..CFG.eventsPath end
    pcall(setclipboard,evPath.."."..selCall.n); setSt("Remote path copied!")
end)
bCopyArgs.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    pcall(setclipboard,"{"..a2s(selCall.a).."}"); setSt("Args copied!")
end)
bBlockBtn.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    local c2=cfg(selCall.n); c2.block=not c2.block
    pcall(function()
        bBlockBtn.Text=c2.block and "Block: ON" or "Block: OFF"
        bBlockBtn.BackgroundColor3=c2.block and Color3.fromRGB(140,22,22) or Color3.fromRGB(52,16,16)
    end)
    setSt((c2.block and "Blocked: " or "Unblocked: ")..selCall.n)
end)
bRunCode.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    local code=genCode(selCall)
    local ok,fn=pcall(loadstring,code)
    if ok and fn then
        local ok2,err=pcall(fn)
        setSt(ok2 and "Ran!" or "Error: "..tostring(err))
    else setSt("loadstring failed") end
end)
bExclude.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    local n=selCall.n; excludeSet[n]=not excludeSet[n]
    bExclude.Text=excludeSet[n] and "Include" or "Exclude"
    setSt(excludeSet[n] and "Excluded: "..n or "Included: "..n)
end)
bClrMod.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    cfg(selCall.n).mod=nil; setSt("Mod cleared: "..selCall.n)
end)
local function doClearCalls()
    callLog={}; selCall=nil
    for _,c in ipairs(callSF:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    pcall(function()
        callSF.CanvasSize=UDim2.new(0,0,0,0)
        callCountL.Text="0"; codeTitle.Text="← click a call"
        typeBadge.Text=""; codeTxt.Text="-- cleared"
    end)
end
local function doTestHook()
    local lines={}
    lines[#lines+1]="getrawmetatable: "..tostring(pcall(function() return type(getrawmetatable(game))=="table" end))
    lines[#lines+1]="getnamecallmethod: "..(getnamecallmethod and "YES" or "NO")
    lines[#lines+1]="hook installed: "..tostring(namecallInstalled)
    local cc=0; for _ in pairs(remoteCache) do cc=cc+1 end
    lines[#lines+1]="cache size: "..cc
    local evs=RS:FindFirstChild(CFG.eventsPath)
    local rem=evs and evs:FindFirstChildWhichIsA("RemoteEvent")
    if rem then
        lines[#lines+1]="test remote: "..rem.Name
        lines[#lines+1]="in cache: "..tostring(remoteCache[rem]~=nil)
        if not namecallInstalled then installNC() end
        if namecallInstalled then
            local prev=hookFire; hookFire=true
            pcall(function() rem:FireServer("__TEST__") end)
            task.wait(0.4); hookFire=prev
            if not hookFire and not hookInvoke and not hookDebug then removeNC() end
            lines[#lines+1]="-> TEST call should appear in list"
        end
    else lines[#lines+1]="No RemoteEvent found - run Scan RS first" end
    local h=#lines*13+8
    pcall(function()
        codeTxt.Size=UDim2.new(1,-6,0,h); codeTxt.Text=table.concat(lines,"\n")
        codeSF.CanvasSize=UDim2.new(0,0,0,h+6); codeSF.CanvasPosition=Vector2.new(0,0)
        codeTitle.Text="Diagnostics"; typeBadge.Text=""
    end)
end

bClrCalls.MouseButton1Click:Connect(doClearCalls)
bTest2.MouseButton1Click:Connect(doTestHook)
hClrAll.MouseButton1Click:Connect(doClearCalls)
hTest.MouseButton1Click:Connect(doTestHook)

-- ================================================================
-- NAMECALL HOOK
-- ================================================================
installNC = function()
    if namecallInstalled then return true end
    local ok,mt=pcall(getrawmetatable,game)
    if not ok or not mt then setSt("[ERR] getrawmetatable failed"); return false end
    if not pcall(setreadonly,mt,false) then setSt("[ERR] setreadonly failed"); return false end
    oldNamecall=rawget(mt,"__namecall")
    if not oldNamecall then setSt("[ERR] no __namecall"); pcall(setreadonly,mt,true); return false end
    buildRemoteCache()
    local cc=0; for _ in pairs(remoteCache) do cc=cc+1 end
    setSt("hook ok, "..cc.." cached")
    rawset(mt,"__namecall",function(self,...)
        local method=""
        if getnamecallmethod then
            local m; pcall(function() m=getnamecallmethod() end)
            if type(m)=="string" then method=m end
        end
        if method=="" then
            local a=table.pack(...)
            if type(a[a.n])=="string" then method=a[a.n] end
        end
        local cached=remoteCache[self]
        local isRE,isRF,nm=false,false,"?"
        if cached then
            isRE=cached.isRE; isRF=cached.isRF; nm=cached.nm
        elseif hookDebug and method~="" then
            local n2="?"; pcall(function() n2=self.Name end)
            hookQueue[#hookQueue+1]={[1]="D",m=method,n=n2}
        end
        local capF=hookFire and isRE and method=="FireServer"
        local capI=hookInvoke and isRF and method=="InvokeServer"
        if capF or capI then
            local args=table.pack(...)
            if method~="" and args[args.n]==method then args.n=args.n-1 end
            local clean={}; for i=1,args.n do clean[i]=args[i] end
            bump(nm); ensureR(nm); remLastArgs[nm]=clean
            local c2=cfg(nm); local pass=true
            if c2.filt and c2.filt~="" then
                pass=false
                for _,v in ipairs(clean) do
                    if tostring(v):lower():find(c2.filt:lower(),1,true) then pass=true; break end
                end
            end
            if pass then hookQueue[#hookQueue+1]={[1]=capF and "F" or "I",n=nm,a=clean} end
            if c2.block then return end
            if c2.mod then return oldNamecall(self,table.unpack(c2.mod)) end
        end
        return oldNamecall(self,...)
    end)
    pcall(setreadonly,mt,true)
    namecallInstalled=true; return true
end

removeNC = function()
    if not namecallInstalled then return end
    local ok,mt=pcall(getrawmetatable,game)
    if ok and mt then
        pcall(setreadonly,mt,false)
        rawset(mt,"__namecall",oldNamecall)
        pcall(setreadonly,mt,true)
    end
    oldNamecall=nil; namecallInstalled=false
    hookFire=false; hookInvoke=false; hookDebug=false
    pcall(function()
        hFire.Text="Hook Fire"; hFire.BackgroundColor3=Color3.fromRGB(50,22,105)
        hInv.Text="Hook Invoke"; hInv.BackgroundColor3=Color3.fromRGB(22,52,105)
        hDbg.Text="Debug: OFF"; hDbg.BackgroundColor3=Color3.fromRGB(38,38,18)
    end)
    setSt("Hook removed")
end

hCli.MouseButton1Click:Connect(function()
    if #clientConns>0 then
        for _,c in ipairs(clientConns) do pcall(function() c:Disconnect() end) end
        clientConns={}; clientLastLog={}
        pcall(function() hCli.Text="Watch Client"; hCli.BackgroundColor3=Color3.fromRGB(90,30,30) end)
        setSt("Watch stopped"); return
    end
    local evs=RS:FindFirstChild(CFG.eventsPath)
    if not evs then setSt("[ERR] events folder not found"); return end
    local n=0
    for _,r in ipairs(evs:GetChildren()) do
        if r:IsA("RemoteEvent") then
            local rn=r.Name; ensureR(rn); remoteCache[r]={isRE=true,isRF=false,nm=rn}
            local conn=r.OnClientEvent:Connect(function(...)
                bump(rn); local now=tick(); if now-(clientLastLog[rn] or 0)<0.3 then return end
                clientLastLog[rn]=now; local a={...}
                hookQueue[#hookQueue+1]={[1]="C",n=rn,a=a}
            end)
            clientConns[#clientConns+1]=conn; n=n+1
        end
    end
    pcall(function() hCli.Text="STOP Watch"; hCli.BackgroundColor3=Color3.fromRGB(140,30,30) end)
    setSt("Watching "..n.." remotes")
end)
hFire.MouseButton1Click:Connect(function()
    if hookFire then
        hookFire=false
        pcall(function() hFire.Text="Hook Fire"; hFire.BackgroundColor3=Color3.fromRGB(50,22,105) end)
        if not hookInvoke and not hookDebug then removeNC() end
        setSt("FireServer OFF"); return
    end
    if installNC() then
        hookFire=true
        pcall(function() hFire.Text="STOP Fire"; hFire.BackgroundColor3=Color3.fromRGB(115,28,115) end)
        setSt("Hooking FireServer...")
    end
end)
hInv.MouseButton1Click:Connect(function()
    if hookInvoke then
        hookInvoke=false
        pcall(function() hInv.Text="Hook Invoke"; hInv.BackgroundColor3=Color3.fromRGB(22,52,105) end)
        if not hookFire and not hookDebug then removeNC() end
        setSt("InvokeServer OFF"); return
    end
    if installNC() then
        hookInvoke=true
        pcall(function() hInv.Text="STOP Invoke"; hInv.BackgroundColor3=Color3.fromRGB(22,88,130) end)
        setSt("Hooking InvokeServer...")
    end
end)
hStop.MouseButton1Click:Connect(function()
    for _,c in ipairs(clientConns) do pcall(function() c:Disconnect() end) end
    clientConns={}; clientLastLog={}
    pcall(function() hCli.Text="Watch Client"; hCli.BackgroundColor3=Color3.fromRGB(90,30,30) end)
    hookFire=false; hookInvoke=false; hookDebug=false
    removeNC(); setSt("All stopped")
end)
hDbg.MouseButton1Click:Connect(function()
    hookDebug=not hookDebug
    pcall(function() hDbg.Text=hookDebug and "Debug: ON" or "Debug: OFF"; hDbg.BackgroundColor3=hookDebug and Color3.fromRGB(75,75,18) or Color3.fromRGB(38,38,18) end)
    if hookDebug and not namecallInstalled then installNC() end
    if not hookDebug and not hookFire and not hookInvoke then removeNC() end
    setSt(hookDebug and "Debug ON" or "Debug OFF")
end)

-- ================================================================
-- TAB 3: SPAM
-- ================================================================
local spP=mkTab("Spam")
local spLog=mkLog(spP,UDim2.new(1,-8,1,-234),UDim2.new(0,4,0,230))
local spCfg=mkF(spP,BG2,UDim2.new(1,-8,0,224),UDim2.new(0,4,0,4),7)
mkL(spCfg,"Remote:",UDim2.new(0,50,0,13),UDim2.new(0,4,0,6),TXT2,Enum.Font.Gotham,9)
local spRem=mkTB(spCfg,"remote name",UDim2.new(0,130,0,22),UDim2.new(0,54,0,4))
mkL(spCfg,"Type:",UDim2.new(0,38,0,13),UDim2.new(0,192,0,6),TXT2,Enum.Font.Gotham,9)
local spTE=mkB(spCfg,"Event",Color3.fromRGB(90,36,125),UDim2.new(0,52,0,22),UDim2.new(0,228,0,4))
local spTF=mkB(spCfg,"Func",Color3.fromRGB(34,34,72),UDim2.new(0,46,0,22),UDim2.new(0,284,0,4))
local spIsE=true
spTE.MouseButton1Click:Connect(function() spIsE=true; pcall(function() spTE.BackgroundColor3=Color3.fromRGB(110,46,150); spTF.BackgroundColor3=Color3.fromRGB(34,34,72) end) end)
spTF.MouseButton1Click:Connect(function() spIsE=false; pcall(function() spTF.BackgroundColor3=Color3.fromRGB(42,72,145); spTE.BackgroundColor3=Color3.fromRGB(72,34,105) end) end)
mkL(spCfg,"Args:",UDim2.new(0,36,0,13),UDim2.new(0,4,0,32),TXT2,Enum.Font.Gotham,9)
local spArgs=mkTB(spCfg,'"uuid"',UDim2.new(1,-56,0,22),UDim2.new(0,44,0,30))
mkL(spCfg,"Delay:",UDim2.new(0,40,0,13),UDim2.new(0,4,0,58),TXT2,Enum.Font.Gotham,9)
local spDly=mkTB(spCfg,"0.5",UDim2.new(0,44,0,22),UDim2.new(0,46,0,56))
local spSt2=mkB(spCfg,"Start",Color3.fromRGB(28,90,34),UDim2.new(0,55,0,22),UDim2.new(0,96,0,56))
local spSp=mkB(spCfg,"Stop",Color3.fromRGB(90,28,28),UDim2.new(0,50,0,22),UDim2.new(0,156,0,56))
local spRL=mkL(spCfg,"--",UDim2.new(0,80,0,13),UDim2.new(0,212,0,60),GREEN,Enum.Font.GothamBold,10)
mkF(spCfg,LINE,UDim2.new(1,-8,0,1),UDim2.new(0,4,0,84))
mkL(spCfg,"Multi (name|args|delay):",UDim2.new(1,-8,0,12),UDim2.new(0,4,0,88),TXT2,Enum.Font.GothamBold,9)
local spMT=mkTB(spCfg,'collect|"uuid"|0.5\nuploadAll||5',UDim2.new(1,-8,0,48),UDim2.new(0,4,0,102),true)
local spMS=mkB(spCfg,"Multi Start",Color3.fromRGB(22,80,52),UDim2.new(0,85,0,22),UDim2.new(0,4,0,154))
local spMX=mkB(spCfg,"Multi Stop",Color3.fromRGB(80,28,28),UDim2.new(0,82,0,22),UDim2.new(0,94,0,154))
mkF(spCfg,LINE,UDim2.new(1,-8,0,1),UDim2.new(0,4,0,182))
mkL(spCfg,"Preset:",UDim2.new(0,50,0,12),UDim2.new(0,4,0,186),TXT2,Enum.Font.GothamBold,9)
local spPN=mkTB(spCfg,"name",UDim2.new(0,100,0,22),UDim2.new(0,4,0,200))
local spSv=mkB(spCfg,"Save",Color3.fromRGB(50,70,22),UDim2.new(0,48,0,22),UDim2.new(0,108,0,200))
local spLd=mkB(spCfg,"Load",Color3.fromRGB(22,52,76),UDim2.new(0,48,0,22),UDim2.new(0,160,0,200))
local spLs=mkB(spCfg,"List",Color3.fromRGB(52,46,16),UDim2.new(0,44,0,22),UDim2.new(0,212,0,200))
local presets={}
spSv.MouseButton1Click:Connect(function() local n=spPN.Text:match("^%s*(.-)%s*$"); if n~="" then presets[n]={r=spRem.Text,a=spArgs.Text,d=spDly.Text,e=spIsE,m=spMT.Text}; spLog.add("[SAVE] "..n); spLog.flush() end end)
spLd.MouseButton1Click:Connect(function() local n=spPN.Text:match("^%s*(.-)%s*$"); local p=presets[n]; if not p then spLog.add("[!] "..n); spLog.flush(); return end; pcall(function() spRem.Text=p.r or ""; spArgs.Text=p.a or ""; spDly.Text=p.d or "0.5"; spIsE=p.e~=false; spMT.Text=p.m or "" end); spLog.add("[LOAD] "..n); spLog.flush() end)
spLs.MouseButton1Click:Connect(function() spLog.header("Presets"); local n=0; for k in pairs(presets) do spLog.add("  "..k); n=n+1 end; if n==0 then spLog.add("  (none)") end; spLog.flush() end)
spSt2.MouseButton1Click:Connect(function()
    if spActive then return end
    local name=spRem.Text:match("^%s*(.-)%s*$"); if name=="" then spLog.add("[!] Enter name"); spLog.flush(); return end
    local dly=tonumber(spDly.Text) or 0.5; local raw=spArgs.Text; spActive=true; spCnt=0; spLog.header("Spam: "..name)
    task.spawn(function()
        local t0=tick()
        while spActive do
            local ev=RS:FindFirstChild(CFG.eventsPath); if not ev then break end
            local r=ev:FindFirstChild(name); if not r then spLog.add("[!] not found"); spLog.flush(); spActive=false; break end
            if spIsE then pcall(function() r:FireServer(table.unpack(raw~="" and parseA(raw) or {})) end)
            else pcall(function() r:InvokeServer(table.unpack(raw~="" and parseA(raw) or {})) end) end
            spCnt=spCnt+1; local e=tick()-t0; pcall(function() spRL.Text=(e>0 and math.floor(spCnt/e*10)/10 or 0).."/s" end)
            task.wait(dly)
        end
        spLog.add("[STOP] "..spCnt); spLog.flush()
    end)
end)
spSp.MouseButton1Click:Connect(function() spActive=false end)
spMS.MouseButton1Click:Connect(function()
    if multiActive then return end; local rems={}
    for line in (spMT.Text.."\n"):gmatch("([^\n]*)\n") do
        local pp={}; for p in (line.."|"):gmatch("([^|]*)|") do pp[#pp+1]=p end
        local n=pp[1] and pp[1]:match("^%s*(.-)%s*$") or ""
        if n~="" then rems[#rems+1]={n=n,a=pp[2] or "",d=tonumber(pp[3]) or 1} end
    end
    if #rems==0 then spLog.add("[!] empty"); spLog.flush(); return end
    multiActive=true; spLog.header("Multi: "..#rems)
    for _,r in ipairs(rems) do task.spawn(function()
        local ev=RS:FindFirstChild(CFG.eventsPath); if not ev then return end
        local rem=ev:FindFirstChild(r.n); if not rem then return end
        while multiActive do
            if rem:IsA("RemoteEvent") then pcall(function() rem:FireServer(table.unpack(r.a~="" and parseA(r.a) or {})) end)
            else pcall(function() rem:InvokeServer(table.unpack(r.a~="" and parseA(r.a) or {})) end) end
            task.wait(r.d)
        end
    end) end
    spLog.add("[ON]"); spLog.flush()
end)
spMX.MouseButton1Click:Connect(function() multiActive=false; spLog.add("[STOP] multi"); spLog.flush() end)

-- ================================================================
-- TAB 4: DECOMPILE
-- ================================================================
local dP=mkTab("Decompile")
local dLeft=mkF(dP,BG2,UDim2.new(0.33,-5,1,-4),UDim2.new(0,2,0,2),7)
local dHdr=mkF(dLeft,BG3,UDim2.new(1,0,0,28),UDim2.new(0,0,0,0),7)
local dHF=mkF(dHdr,BG3,UDim2.new(1,0,0.5,0),UDim2.new(0,0,0.5,0)); dHF.BorderSizePixel=0
mkL(dHdr,"Scripts",UDim2.new(1,-65,1,0),UDim2.new(0,6,0,0),TXT,Enum.Font.GothamBold,11)
local dScanB=mkB(dHdr,"Scan",Color3.fromRGB(18,48,95),UDim2.new(0,50,0,22),UDim2.new(1,-56,0,3))
local dFilt=mkTB(dLeft,"filter...",UDim2.new(1,-6,0,22),UDim2.new(0,3,0,32))
local dList=mkSF(dLeft,UDim2.new(1,-4,1,-60),UDim2.new(0,2,0,58))
Instance.new("UIListLayout",dList).Padding=UDim.new(0,2)
local dRight=mkF(dP,BG,UDim2.new(0.67,-5,1,-4),UDim2.new(0.33,3,0,2),7)
local dRH=mkF(dRight,BG2,UDim2.new(1,0,0,28),UDim2.new(0,0,0,0),7)
local dRF=mkF(dRH,BG2,UDim2.new(1,0,0.5,0),UDim2.new(0,0,0.5,0)); dRF.BorderSizePixel=0
local dName=mkL(dRH,"No script",UDim2.new(1,-180,1,0),UDim2.new(0,6,0,0),CYAN,Enum.Font.GothamBold,11)
local dCopy=mkB(dRH,"Copy",Color3.fromRGB(12,55,55),UDim2.new(0,45,0,22),UDim2.new(1,-160,0,3))
local dSrch=mkTB(dRH,"search (Enter)",UDim2.new(0,105,0,22),UDim2.new(1,-108,0,3))
local dRems=mkB(dRight,"Scan Remote Calls",Color3.fromRGB(68,44,12),UDim2.new(1,-8,0,22),UDim2.new(0,4,0,32))
local dSF=mkSF(dRight,UDim2.new(1,-6,1,-62),UDim2.new(0,3,0,60))
local dTxt=Instance.new("TextLabel",dSF)
dTxt.Size=UDim2.new(1,-4,0,9999); dTxt.Position=UDim2.new(0,2,0,2)
dTxt.BackgroundTransparency=1; dTxt.TextColor3=Color3.fromRGB(180,225,175)
dTxt.Font=Enum.Font.Code; dTxt.TextSize=11
dTxt.TextXAlignment=Enum.TextXAlignment.Left; dTxt.TextYAlignment=Enum.TextYAlignment.Top
dTxt.TextWrapped=true; dTxt.RichText=false; dTxt.Text="<- Click a script"
local function showSrc(src)
    decompiledSource=src; local out={}; local n=0
    for line in (src.."\n"):gmatch("([^\n]*)\n") do n=n+1; out[#out+1]=string.format("%4d | %s",n,line) end
    local h=n*13+8; pcall(function() dTxt.Size=UDim2.new(1,-4,0,h); dTxt.Text=table.concat(out,"\n"); dSF.CanvasSize=UDim2.new(0,0,0,h+4); dSF.CanvasPosition=Vector2.new(0,0) end)
end
local function decompObj(obj)
    pcall(function() dName.Text=obj.Name; dTxt.Text="Decompiling..." end)
    task.spawn(function()
        local ok,r=pcall(decompile,obj)
        if ok and type(r)=="string" and #r>10 then showSrc(r); setSt("OK: "..obj.Name)
        else
            local ok2,r2=pcall(getscriptbytecode,obj)
            if ok2 and type(r2)=="string" and #r2>0 then showSrc("-- bytecode\n"..r2); setSt("Bytecode")
            else pcall(function() dTxt.Text="Failed: "..tostring(r) end); setSt("Failed") end
        end
    end)
end
local function buildList(flt)
    for _,c in ipairs(dList:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
    local n=0
    for _,s in ipairs(scriptCache) do
        if flt=="" or s.nm:lower():find(flt:lower(),1,true) then
            local it=Instance.new("TextButton",dList); it.Size=UDim2.new(1,-4,0,20); it.Text=s.nm
            it.BackgroundColor3=BG3; it.BorderSizePixel=0; it.RichText=false
            it.TextColor3=s.ref:IsA("LocalScript") and CYAN or (s.ref:IsA("ModuleScript") and PURP or TXT1)
            it.Font=Enum.Font.Gotham; it.TextSize=10; it.TextXAlignment=Enum.TextXAlignment.Left
            Instance.new("UICorner",it).CornerRadius=UDim.new(0,4)
            local pd=Instance.new("UIPadding",it); pd.PaddingLeft=UDim.new(0,5)
            local ref=s.ref
            it.MouseButton1Click:Connect(function()
                for _,c2 in ipairs(dList:GetChildren()) do if c2:IsA("TextButton") then pcall(function() c2.BackgroundColor3=BG3 end) end end
                pcall(function() it.BackgroundColor3=Color3.fromRGB(22,44,72) end); decompObj(ref)
            end); n=n+1
        end
    end
    pcall(function() dList.CanvasSize=UDim2.new(0,0,0,n*22+4) end)
end
dScanB.MouseButton1Click:Connect(function()
    scriptCache={}
    local function f(o)
        for _,c in ipairs(o:GetChildren()) do
            if c:IsA("LocalScript") or c:IsA("ModuleScript") or c:IsA("Script") then
                scriptCache[#scriptCache+1]={nm=c.Name,ref=c}
            end
            pcall(function() f(c) end)
        end
    end
    pcall(function() f(game) end); buildList(""); setSt("Scripts: "..#scriptCache)
end)
dFilt:GetPropertyChangedSignal("Text"):Connect(function() pcall(function() buildList(dFilt.Text) end) end)
dCopy.MouseButton1Click:Connect(function() if decompiledSource~="" then pcall(setclipboard,decompiledSource); setSt("Copied") end end)
dSrch.FocusLost:Connect(function(enter)
    if not enter or decompiledSource=="" or dSrch.Text=="" then return end
    local kw=dSrch.Text; local out={}; local n=0; local ln=0
    for line in (decompiledSource.."\n"):gmatch("([^\n]*)\n") do
        ln=ln+1; if line:lower():find(kw:lower(),1,true) then out[#out+1]=string.format("%4d | %s",ln,line); n=n+1 end
    end
    local h=math.max(n,1)*13+8; pcall(function() dTxt.Size=UDim2.new(1,-4,0,h); dTxt.Text=n>0 and table.concat(out,"\n") or "No: "..kw; dSF.CanvasSize=UDim2.new(0,0,0,h+4) end)
    if n>0 then setSt(n.." matches") end
end)
dRems.MouseButton1Click:Connect(function()
    if decompiledSource=="" then setSt("Decompile first"); return end
    local out={}; local n=0; local ln=0
    for line in (decompiledSource.."\n"):gmatch("([^\n]*)\n") do
        ln=ln+1
        if line:find("FireServer") or line:find("InvokeServer") or line:find("FireClient") then
            out[#out+1]=string.format("%4d | %s",ln,line:match("^%s*(.-)%s*$")); n=n+1
        end
    end
    local h=math.max(n,1)*13+8; pcall(function() dTxt.Size=UDim2.new(1,-4,0,h); dTxt.Text=n>0 and table.concat(out,"\n") or "No remote calls"; dSF.CanvasSize=UDim2.new(0,0,0,h+4) end)
    setSt("Remote calls: "..n)
end)

-- ================================================================
-- TAB 5: PLAYERS
-- ================================================================
local plP=mkTab("Players")
local plLog=mkLog(plP,UDim2.new(1,-8,1,-38),UDim2.new(0,4,0,34))
local plRow=mkRow(plP,4,26)
local plAll=plRow("All",Color3.fromRGB(18,50,105)); local plSelf=plRow("Self",Color3.fromRGB(18,66,40))
local plLead=plRow("Leaderstats",Color3.fromRGB(62,52,10)); local plAttr=plRow("Attributes",Color3.fromRGB(42,22,82))
local plCp=plRow("Copy",Color3.fromRGB(12,55,55)); local plCl=plRow("Clear",Color3.fromRGB(50,10,10))
local function scanPl(p,full)
    plLog.add("[PLR] "..p.Name.." id:"..p.UserId)
    pcall(function() for k,v in pairs(p:GetAttributes()) do plLog.add("  "..k.."="..tostring(v)) end end)
    local ls=p:FindFirstChild("leaderstats")
    if ls then for _,v in ipairs(ls:GetChildren()) do plLog.add("  "..v.Name.."="..tostring(v.Value)) end end
    if full then pcall(function() for _,c in ipairs(p:GetChildren()) do if c.Name~="leaderstats" then plLog.add("  ["..c.ClassName.."] "..c.Name) end end end) end
end
plAll.MouseButton1Click:Connect(function() plLog.clear(); plLog.header("All"); for _,p in ipairs(Players:GetPlayers()) do scanPl(p,false) end; plLog.flush() end)
plSelf.MouseButton1Click:Connect(function() plLog.clear(); plLog.header("Self"); scanPl(LP,true); plLog.flush() end)
plLead.MouseButton1Click:Connect(function()
    plLog.clear(); plLog.header("Leaderstats")
    for _,p in ipairs(Players:GetPlayers()) do
        local ls=p:FindFirstChild("leaderstats")
        if ls then plLog.add(p.Name); for _,v in ipairs(ls:GetChildren()) do plLog.add("  "..v.Name.."="..tostring(v.Value)) end end
    end
    plLog.flush()
end)
plAttr.MouseButton1Click:Connect(function()
    plLog.clear(); plLog.header("Attributes")
    for _,p in ipairs(Players:GetPlayers()) do
        local n=0; for _ in pairs(p:GetAttributes()) do n=n+1 end
        if n>0 then plLog.add(p.Name); for k,v in pairs(p:GetAttributes()) do plLog.add("  "..k.."="..tostring(v)) end end
    end
    plLog.flush()
end)
plCp.MouseButton1Click:Connect(function() plLog.copy() end)
plCl.MouseButton1Click:Connect(function() plLog.clear() end)

-- ================================================================
-- TAB 6: EXECUTOR  (fully safe - no crash)
-- ================================================================
local exP=mkTab("Executor")
local exLog=mkLog(exP,UDim2.new(1,-8,1,-38),UDim2.new(0,4,0,34))
local exRow=mkRow(exP,4,26)
local exChk=exRow("Run Check",Color3.fromRGB(20,75,42))
local exCp=exRow("Copy",Color3.fromRGB(12,55,55))
local exCl=exRow("Clear",Color3.fromRGB(50,10,10))

local APIS={
    {"getrawmetatable",   function() local ok,r=pcall(function() return type(getrawmetatable(game))=="table" end); return ok and r end},
    {"setreadonly",       function() local ok=pcall(function() local m=getrawmetatable(game); setreadonly(m,false); setreadonly(m,true) end); return ok end},
    {"getnamecallmethod", function() return type(getnamecallmethod)=="function" end},
    {"setclipboard",      function() local ok=pcall(function() setclipboard("") end); return ok end},
    {"loadstring",        function() local ok,f=pcall(loadstring,"return 1"); return ok and type(f)=="function" end},
    {"newcclosure",       function() return type(newcclosure)=="function" end},
    {"hookfunction",      function() return type(hookfunction)=="function" end},
    {"decompile",         function() return type(decompile)=="function" end},
    {"getscriptbytecode", function() return type(getscriptbytecode)=="function" end},
    {"gethui",            function() local ok,r=pcall(gethui); return ok and r~=nil end},
    {"Drawing",           function() return type(Drawing)=="table" end},
    {"firesignal",        function() return type(firesignal)=="function" end},
    {"getinstances",      function() return type(getinstances)=="function" end},
    {"fireclickdetector", function() return type(fireclickdetector)=="function" end},
    {"isreadonly",        function() local ok,r=pcall(isreadonly,getrawmetatable(game)); return ok and r end},
    {"identifyexecutor",  function() local ok,r=pcall(identifyexecutor); return ok and r~=nil end},
}
exChk.MouseButton1Click:Connect(function()
    exLog.clear(); exLog.header("Executor Check"); local pass,fail=0,0
    for _,ck in ipairs(APIS) do
        local ok,result=pcall(ck[2])
        if ok and result==true then exLog.add("[OK] "..ck[1]); pass=pass+1
        else exLog.add("[--] "..ck[1]); fail=fail+1 end
    end
    exLog.add("")
    exLog.add("Passed: "..pass.."/"..#APIS)
    local idOk,idName=pcall(identifyexecutor)
    if idOk and idName then exLog.add("Executor: "..tostring(idName)) end
    exLog.flush(); setSt(pass.."/"..#APIS.." OK")
end)
exCp.MouseButton1Click:Connect(function() exLog.copy() end)
exCl.MouseButton1Click:Connect(function() exLog.clear() end)

-- ================================================================
-- TAB 7: CONFIG
-- ================================================================
local cfgP=mkTab("Config")
local cfgSF=mkSF(cfgP,UDim2.new(1,-8,1,-4),UDim2.new(0,4,0,4))
local cfgCont=Instance.new("Frame",cfgSF)
cfgCont.BackgroundTransparency=1; cfgCont.BorderSizePixel=0; cfgCont.Size=UDim2.new(1,0,0,0)
local cfgLL=Instance.new("UIListLayout",cfgCont)
cfgLL.Padding=UDim.new(0,4); cfgLL.SortOrder=Enum.SortOrder.LayoutOrder

local cfgOrder=0
local function cfgSection(title)
    cfgOrder=cfgOrder+1
    local hdr=mkF(cfgCont,BG3,UDim2.new(1,-4,0,20),UDim2.new(0,2,0,0),4)
    hdr.LayoutOrder=cfgOrder
    mkL(hdr,"▸ "..title,UDim2.new(1,-8,1,0),UDim2.new(0,6,0,0),AMBER,Enum.Font.GothamBold,10)
end
local function cfgRow(labelTxt)
    cfgOrder=cfgOrder+1
    local row=mkF(cfgCont,BG2,UDim2.new(1,-4,0,26),UDim2.new(0,2,0,0),4)
    row.LayoutOrder=cfgOrder
    mkL(row,labelTxt,UDim2.new(0,140,1,0),UDim2.new(0,6,0,0),TXT1,Enum.Font.Gotham,10)
    local box=mkTB(row,"",UDim2.new(0,180,0,20),UDim2.new(0,148,0.5,-10))
    local btn=mkB(row,"Apply",Color3.fromRGB(18,62,22),UDim2.new(0,52,0,20),UDim2.new(0,334,0.5,-10))
    return box, btn
end

-- HOTKEYS
cfgSection("HOTKEYS  (bấm Apply rồi nhấn phím)")
local hkTogBox,hkTogBtn = cfgRow("Toggle GUI:")
hkTogBox.Text=CFG.hotkeyToggle
hkTogBtn.MouseButton1Click:Connect(function()
    hkTogBox.Text="< press key >"
    if not UIS then hkTogBox.Text="UIS N/A"; return end
    local conn; conn=UIS.InputBegan:Connect(function(inp,gp)
        if gp then return end
        pcall(function()
            if inp.UserInputType==Enum.UserInputType.Keyboard then
                local kn=tostring(inp.KeyCode.Name)
                CFG.hotkeyToggle=kn; hkTogBox.Text=kn
                hkHint.Text="["..kn.."] toggle"
                conn:Disconnect(); setSt("Toggle: "..kn)
            end
        end)
    end)
end)

local hkFireBox,hkFireBtn = cfgRow("Quick Hook Fire:")
hkFireBox.Text=CFG.hotkeyHookFire
hkFireBtn.MouseButton1Click:Connect(function()
    hkFireBox.Text="< press key >"
    if not UIS then hkFireBox.Text="UIS N/A"; return end
    local conn; conn=UIS.InputBegan:Connect(function(inp,gp)
        if gp then return end
        pcall(function()
            if inp.UserInputType==Enum.UserInputType.Keyboard then
                local kn=tostring(inp.KeyCode.Name)
                CFG.hotkeyHookFire=kn; hkFireBox.Text=kn
                conn:Disconnect(); setSt("Fire key: "..kn)
            end
        end)
    end)
end)

-- PATHS
cfgSection("PATHS & SCAN")
local evBox,evBtn=cfgRow("Events folder:"); evBox.Text=CFG.eventsPath
evBtn.MouseButton1Click:Connect(function()
    local v=evBox.Text:match("^%s*(.-)%s*$")
    if v~="" then CFG.eventsPath=v; setSt("Events: "..v) end
end)
local drBox,drBtn=cfgRow("Scan RS depth:"); drBox.Text=tostring(CFG.scanDepthRS)
drBtn.MouseButton1Click:Connect(function()
    local n=tonumber(drBox.Text); if n then CFG.scanDepthRS=math.clamp(n,1,12); setSt("RS depth: "..CFG.scanDepthRS) end
end)
local dwBox,dwBtn=cfgRow("Scan WS depth:"); dwBox.Text=tostring(CFG.scanDepthWS)
dwBtn.MouseButton1Click:Connect(function()
    local n=tonumber(dwBox.Text); if n then CFG.scanDepthWS=math.clamp(n,1,12); setSt("WS depth: "..CFG.scanDepthWS) end
end)
local mcBox,mcBtn=cfgRow("Max hook calls:"); mcBox.Text=tostring(CFG.maxCalls)
mcBtn.MouseButton1Click:Connect(function()
    local n=tonumber(mcBox.Text); if n then CFG.maxCalls=math.clamp(n,50,2000); setSt("Max: "..CFG.maxCalls) end
end)

-- WINDOW
cfgSection("WINDOW")
local wwBox,wwBtn=cfgRow("Width:"); wwBox.Text=tostring(CFG.winW)
local whBox,whBtn=cfgRow("Height:"); whBox.Text=tostring(CFG.winH)
wwBtn.MouseButton1Click:Connect(function()
    local n=tonumber(wwBox.Text)
    if n then CFG.winW=math.clamp(n,400,1400); pcall(function() WIN.Size=UDim2.new(0,CFG.winW,0,CFG.winH) end); setSt("W: "..CFG.winW) end
end)
whBtn.MouseButton1Click:Connect(function()
    local n=tonumber(whBox.Text)
    if n then CFG.winH=math.clamp(n,300,900); pcall(function() WIN.Size=UDim2.new(0,CFG.winW,0,CFG.winH) end); setSt("H: "..CFG.winH) end
end)
cfgOrder=cfgOrder+1
local resetBtn=mkB(cfgCont,"Reset Position",Color3.fromRGB(44,28,70),UDim2.new(1,-4,0,24),UDim2.new(0,2,0,0))
resetBtn.LayoutOrder=cfgOrder
resetBtn.MouseButton1Click:Connect(function()
    pcall(function() WIN.Position=UDim2.new(0.5,-CFG.winW/2,0.5,-CFG.winH/2) end)
end)

-- Update canvas size
local function updateCfgCanvas()
    local h=cfgLL.AbsoluteContentSize.Y+20
    pcall(function() cfgCont.Size=UDim2.new(1,0,0,h); cfgSF.CanvasSize=UDim2.new(0,0,0,h) end)
end
task.delay(0.5,updateCfgCanvas)
cfgLL:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCfgCanvas)

-- ================================================================
-- START
-- ================================================================
tabs["Scan"].BackgroundColor3=TACC["Scan"]
tabs["Scan"].TextColor3=Color3.fromRGB(255,255,255)
pages["Scan"].Visible=true
curTab="Scan"
setSt("Ready  ["..CFG.hotkeyToggle.."] = toggle GUI")