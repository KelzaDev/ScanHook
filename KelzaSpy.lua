--[[  Kelza SPY ]]

local Players=game:GetService("Players")
local RS=game:GetService("ReplicatedStorage")
local WS=game:GetService("Workspace")
local LP=Players.LocalPlayer

-- global state
local hookFire,hookInvoke,hookDebug=false,false,false
local namecallInstalled,oldNamecall=false,nil
local hookQueue={}
local clientConns,clientLastLog={},{}
local remCfg,remFreq,remLastArgs,remHist={},{},{},{}
local knownR,pendingR={},{}
local selR,decompiledSource,diffSnap,scriptCache=nil,"",nil,{}
local spActive,spCnt,multiActive=false,0,false

-- Kelza Spy state
local callLog={}        -- list of {n, t, a, ts}
local selCall=nil       -- currently selected call entry
local excludeSet={}     -- remote names to hide
local MAX_CALLS=300

-- ================================================================
-- REMOTE CACHE
-- ================================================================
local remoteCache={}
local function buildRemoteCache()
    remoteCache={}
    local function scanFolder(folder,depth)
        if depth>6 then return end
        pcall(function()
            for _,r in ipairs(folder:GetChildren()) do
                local isRE,isRF=false,false
                pcall(function() isRE=r:IsA("RemoteEvent") end)
                if not isRE then pcall(function() isRF=r:IsA("RemoteFunction") end) end
                if isRE or isRF then
                    local nm=""; pcall(function() nm=r.Name end)
                    remoteCache[r]={isRE=isRE,isRF=isRF,nm=nm}
                end
                local ok,ch=pcall(function() return r:GetChildren() end)
                if ok and ch and #ch>0 then scanFolder(r,depth+1) end
            end
        end)
    end
    pcall(function() scanFolder(RS,0) end)
    pcall(function() scanFolder(WS,0) end)
end

local function cfg(n) if not remCfg[n] then remCfg[n]={block=false,mod=nil,filt=nil} end; return remCfg[n] end
local function freq(n) if not remFreq[n] then remFreq[n]={c=0,t=tick(),r=0} end; return remFreq[n] end
local function bump(n) local f=freq(n); f.c=f.c+1; local e=tick()-f.t; if e>=1 then f.r=math.floor(f.c/e*10)/10; f.c=0; f.t=tick() end end
local function hist(n,a) if not remHist[n] then remHist[n]={} end; table.insert(remHist[n],1,{t=os.clock(),a=a}); if #remHist[n]>8 then table.remove(remHist[n]) end end
local function a2s(t) if not t then return "" end; local p={}; for _,v in ipairs(t) do p[#p+1]=(type(v)=="string" and '"'..v..'"' or tostring(v)) end; return table.concat(p,",") end
local function parseA(s) if not s or s=="" then return {} end; local o={}; for p in s:gmatch("[^,]+") do local v=p:match("^%s*(.-)%s*$"); local n=tonumber(v); if n then o[#o+1]=n elseif v=="true" then o[#o+1]=true elseif v=="false" then o[#o+1]=false else o[#o+1]=v:match('^["\'](.+)["\']$') or v end end; return o end
local function ensureR(n) if not n or n=="" or n=="?" or knownR[n] then return end; knownR[n]=true; pendingR[#pendingR+1]=n end

-- COLORS
local BG=Color3.fromRGB(10,10,16); local BG1=Color3.fromRGB(16,16,24); local BG2=Color3.fromRGB(22,22,34); local BG3=Color3.fromRGB(28,28,44)
local TXT=Color3.fromRGB(220,225,255); local TXT1=Color3.fromRGB(140,145,180); local TXT2=Color3.fromRGB(70,73,110); local LINE=Color3.fromRGB(35,35,55)
local BLUE=Color3.fromRGB(70,145,255); local PURP=Color3.fromRGB(145,70,255); local GREEN=Color3.fromRGB(70,215,135); local RED=Color3.fromRGB(215,65,65); local AMBER=Color3.fromRGB(235,170,50); local CYAN=Color3.fromRGB(50,205,200)
local TACC={Scan=BLUE,Hook=PURP,Spam=RED,Decompile=CYAN,Players=AMBER,Executor=GREEN}

-- GUI root
local SG=Instance.new("ScreenGui"); SG.Name="SHT36"; SG.ResetOnSpawn=false; SG.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
if not pcall(function() SG.Parent=game:GetService("CoreGui") end) then
    if not pcall(function() SG.Parent=gethui() end) then SG.Parent=LP.PlayerGui end
end

local WIN=Instance.new("Frame",SG); WIN.Size=UDim2.new(0,860,0,580); WIN.Position=UDim2.new(0.5,-430,0.5,-290); WIN.BackgroundColor3=BG; WIN.BorderSizePixel=0; WIN.Active=true; WIN.Draggable=true
Instance.new("UICorner",WIN).CornerRadius=UDim.new(0,10)
local TBar=Instance.new("Frame",WIN); TBar.Size=UDim2.new(1,0,0,40); TBar.BackgroundColor3=BG1; TBar.BorderSizePixel=0; Instance.new("UICorner",TBar).CornerRadius=UDim.new(0,10)
local TBarFix=Instance.new("Frame",TBar); TBarFix.Size=UDim2.new(1,0,0.5,0); TBarFix.Position=UDim2.new(0,0,0.5,0); TBarFix.BackgroundColor3=BG1; TBarFix.BorderSizePixel=0
local titleL=Instance.new("TextLabel",TBar); titleL.Text="Kelza Spy"; titleL.Size=UDim2.new(0,230,1,0); titleL.Position=UDim2.new(0,12,0,0); titleL.BackgroundTransparency=1; titleL.TextColor3=TXT; titleL.Font=Enum.Font.GothamBold; titleL.TextSize=13; titleL.TextXAlignment=Enum.TextXAlignment.Left; titleL.RichText=false
local stBar=Instance.new("TextLabel",TBar); stBar.Size=UDim2.new(0,240,0,20); stBar.Position=UDim2.new(1,-340,0.5,-10); stBar.BackgroundColor3=BG2; stBar.BorderSizePixel=0; stBar.TextColor3=TXT1; stBar.Font=Enum.Font.Gotham; stBar.TextSize=10; stBar.Text="Ready"; stBar.TextXAlignment=Enum.TextXAlignment.Left; stBar.RichText=false; Instance.new("UICorner",stBar).CornerRadius=UDim.new(0,10); local _p=Instance.new("UIPadding",stBar); _p.PaddingLeft=UDim.new(0,8)
local xBtn=Instance.new("TextButton",TBar); xBtn.Text="X"; xBtn.Size=UDim2.new(0,28,0,28); xBtn.Position=UDim2.new(1,-34,0.5,-14); xBtn.BackgroundColor3=Color3.fromRGB(170,38,38); xBtn.TextColor3=TXT; xBtn.Font=Enum.Font.GothamBold; xBtn.TextSize=12; xBtn.BorderSizePixel=0; xBtn.RichText=false; Instance.new("UICorner",xBtn).CornerRadius=UDim.new(0,6)
xBtn.MouseButton1Click:Connect(function() SG:Destroy() end)
local function setSt(m) pcall(function() stBar.Text=tostring(m) end) end

local TABS_BAR=Instance.new("Frame",WIN); TABS_BAR.Size=UDim2.new(1,-16,0,28); TABS_BAR.Position=UDim2.new(0,8,0,44); TABS_BAR.BackgroundTransparency=1
local tbl=Instance.new("UIListLayout",TABS_BAR); tbl.FillDirection=Enum.FillDirection.Horizontal; tbl.Padding=UDim.new(0,4)
local CONT=Instance.new("Frame",WIN); CONT.Size=UDim2.new(1,-16,1,-86); CONT.Position=UDim2.new(0,8,0,76); CONT.BackgroundColor3=BG1; CONT.BorderSizePixel=0; Instance.new("UICorner",CONT).CornerRadius=UDim.new(0,8)

-- ================================================================
-- WIDGET HELPERS
-- ================================================================
local function mkF(p,bg,sz,pos,r) local f=Instance.new("Frame",p); f.BackgroundColor3=bg or BG2; f.BorderSizePixel=0; f.Size=sz or UDim2.new(1,0,1,0); f.Position=pos or UDim2.new(0,0,0,0); if r then Instance.new("UICorner",f).CornerRadius=UDim.new(0,r) end; return f end
local function mkL(p,t,sz,pos,c,fn,ts) local l=Instance.new("TextLabel",p); l.Text=t or ""; l.Size=sz or UDim2.new(1,0,0,14); l.Position=pos or UDim2.new(0,0,0,0); l.BackgroundTransparency=1; l.TextColor3=c or TXT1; l.Font=fn or Enum.Font.Gotham; l.TextSize=ts or 11; l.TextXAlignment=Enum.TextXAlignment.Left; l.TextWrapped=true; l.RichText=false; return l end
local function mkB(p,t,bg,sz,pos) local b=Instance.new("TextButton",p); b.Text=t; b.Size=sz or UDim2.new(0,70,0,24); b.Position=pos or UDim2.new(0,0,0,0); b.BackgroundColor3=bg or BG3; b.TextColor3=TXT; b.Font=Enum.Font.GothamBold; b.TextSize=10; b.BorderSizePixel=0; b.RichText=false; Instance.new("UICorner",b).CornerRadius=UDim.new(0,5); return b end
local function mkTB(p,ph,sz,pos,ml) local t=Instance.new("TextBox",p); t.PlaceholderText=ph or ""; t.Text=""; t.Size=sz or UDim2.new(1,0,0,22); t.Position=pos or UDim2.new(0,0,0,0); t.BackgroundColor3=BG3; t.TextColor3=TXT; t.PlaceholderColor3=TXT2; t.Font=Enum.Font.Code; t.TextSize=10; t.BorderSizePixel=0; t.ClearTextOnFocus=false; t.TextXAlignment=Enum.TextXAlignment.Left; t.MultiLine=ml or false; t.RichText=false; Instance.new("UICorner",t).CornerRadius=UDim.new(0,5); local pd=Instance.new("UIPadding",t); pd.PaddingLeft=UDim.new(0,6); return t end
local function mkSF(p,sz,pos) local s=Instance.new("ScrollingFrame",p); s.Size=sz or UDim2.new(1,0,1,0); s.Position=pos or UDim2.new(0,0,0,0); s.BackgroundTransparency=1; s.BorderSizePixel=0; s.ScrollBarThickness=3; s.ScrollBarImageColor3=BLUE; s.CanvasSize=UDim2.new(0,0,0,0); return s end
local function mkRow(p,y,h) local bar=mkF(p,BG,UDim2.new(1,-8,0,h),UDim2.new(0,4,0,y)); bar.BackgroundTransparency=1; local ll=Instance.new("UIListLayout",bar); ll.FillDirection=Enum.FillDirection.Horizontal; ll.Padding=UDim.new(0,4); ll.VerticalAlignment=Enum.VerticalAlignment.Center; return function(t,bg) local b=mkB(bar,t,bg,UDim2.new(0,0,0,h-4)); b.AutomaticSize=Enum.AutomaticSize.X; local pd=Instance.new("UIPadding",b); pd.PaddingLeft=UDim.new(0,8); pd.PaddingRight=UDim.new(0,8); return b end end

-- ================================================================
-- LOG WIDGET
-- ================================================================
local LINE_H=13; local CHUNK_SIZE=300
local function mkLog(p,sz,pos)
    local bg=mkF(p,BG,sz,pos,7)
    local sf=mkSF(bg,UDim2.new(1,-4,1,-4),UDim2.new(0,2,0,2))
    local container=Instance.new("Frame",sf); container.BackgroundTransparency=1; container.BorderSizePixel=0; container.Size=UDim2.new(1,0,0,0)
    local buf={}; local MAX=5000; local chunkLabels={}
    local function makeLabel() local lbl=Instance.new("TextLabel",container); lbl.BackgroundTransparency=1; lbl.TextColor3=Color3.fromRGB(180,215,175); lbl.Font=Enum.Font.Code; lbl.TextSize=11; lbl.TextXAlignment=Enum.TextXAlignment.Left; lbl.TextYAlignment=Enum.TextYAlignment.Top; lbl.TextWrapped=true; lbl.RichText=false; lbl.Text=""; return lbl end
    local api={}
    function api.add(t) buf[#buf+1]=tostring(t); if #buf>MAX then table.remove(buf,1) end end
    function api.flush()
        local total=#buf; if total==0 then return end
        local numC=math.ceil(total/CHUNK_SIZE)
        while #chunkLabels<numC do chunkLabels[#chunkLabels+1]=makeLabel() end
        for i=numC+1,#chunkLabels do pcall(function() chunkLabels[i].Text="" end) end
        for ci=1,numC do local s=(ci-1)*CHUNK_SIZE+1; local e=math.min(ci*CHUNK_SIZE,total); local lines={}; for i=s,e do lines[#lines+1]=buf[i] end; local h=(e-s+1)*LINE_H; local y=(ci-1)*CHUNK_SIZE*LINE_H; pcall(function() local lbl=chunkLabels[ci]; lbl.Size=UDim2.new(1,-6,0,h+4); lbl.Position=UDim2.new(0,3,0,y+2); lbl.Text=table.concat(lines,"\n") end) end
        local totalH=total*LINE_H+12; pcall(function() container.Size=UDim2.new(1,0,0,totalH); sf.CanvasSize=UDim2.new(0,0,0,totalH); sf.CanvasPosition=Vector2.new(0,totalH+9999) end)
    end
    function api.header(t) api.add(""); api.add("+-- "..t.." "..string.rep("-",math.max(0,32-#t))); api.flush() end
    function api.clear() buf={}; for _,lbl in ipairs(chunkLabels) do pcall(function() lbl.Text="" end) end; pcall(function() container.Size=UDim2.new(1,0,0,0); sf.CanvasSize=UDim2.new(0,0,0,0); sf.CanvasPosition=Vector2.new(0,0) end) end
    function api.copy() pcall(setclipboard,table.concat(buf,"\n")); setSt("Copied!") end
    return api
end

-- ================================================================
-- TAB SYSTEM
-- ================================================================
local tabs,pages,curTab={},{},nil
local function mkTab(name)
    local b=Instance.new("TextButton",TABS_BAR); b.Text=name; b.Size=UDim2.new(0,0,1,0); b.AutomaticSize=Enum.AutomaticSize.X; b.BackgroundColor3=BG2; b.TextColor3=TXT2; b.Font=Enum.Font.GothamBold; b.TextSize=10; b.BorderSizePixel=0; b.RichText=false
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,5); local pd=Instance.new("UIPadding",b); pd.PaddingLeft=UDim.new(0,10); pd.PaddingRight=UDim.new(0,10)
    local pg=mkF(CONT,BG1,UDim2.new(1,0,1,0)); pg.Visible=false
    b.MouseButton1Click:Connect(function()
        if curTab then pcall(function() pages[curTab].Visible=false; tabs[curTab].BackgroundColor3=BG2; tabs[curTab].TextColor3=TXT2 end) end
        curTab=name; pcall(function() pg.Visible=true; b.BackgroundColor3=TACC[name] or BLUE; b.TextColor3=Color3.fromRGB(255,255,255); setSt(name) end)
    end)
    tabs[name]=b; pages[name]=pg; return pg
end

-- ================================================================
-- TAB 1: SCAN
-- ================================================================
local sP=mkTab("Scan")
local sRow=mkRow(sP,4,26)
local bRS=sRow("Scan RS",Color3.fromRGB(18,50,105)); local bWS=sRow("Scan WS",Color3.fromRGB(18,68,42))
local bUID=sRow("UUIDs",Color3.fromRGB(58,30,105)); local bPlt=sRow("Plots",Color3.fromRGB(68,55,12))
local bSnap=sRow("Snapshot",Color3.fromRGB(28,60,50)); local bDiff=sRow("Diff",Color3.fromRGB(62,44,10))
local bJSON=sRow("JSON",Color3.fromRGB(10,52,72)); local bCpS=sRow("Copy",Color3.fromRGB(12,55,55)); local bClS=sRow("Clear",Color3.fromRGB(50,10,10))
local simBar=mkF(sP,BG2,UDim2.new(1,-8,0,24),UDim2.new(0,4,0,34),5)
local simBtn=mkB(simBar,"Watch Sim: OFF",Color3.fromRGB(26,26,44),UDim2.new(0,145,0,20),UDim2.new(0,3,0,2))
local simLbl=mkL(simBar,"",UDim2.new(1,-155,1,0),UDim2.new(0,152,0,0),GREEN,Enum.Font.GothamBold,10)
local sLog=mkLog(sP,UDim2.new(1,-8,1,-66),UDim2.new(0,4,0,62))

local function sTree(obj,d,max,buf)
    if d>max then return end; buf=buf or {}
    pcall(function()
        local ind=string.rep("  ",d); local cn=""; pcall(function() cn=obj.ClassName end); local nm=""; pcall(function() nm=obj.Name end)
        local line=ind.."["..cn.."] "..nm
        local _,isV=pcall(function() return obj:IsA("ValueBase") end)
        if isV then local _,v=pcall(function() return obj.Value end); if v~=nil then line=line..'="'..tostring(v)..'"' end end
        buf[#buf+1]=line
        local _,at=pcall(function() return obj:GetAttributes() end)
        if at then for k,v in pairs(at) do buf[#buf+1]=ind.."  ."..k.."="..tostring(v) end end
        local _,ch=pcall(function() return obj:GetChildren() end)
        if ch then for _,c in ipairs(ch) do sTree(c,d+1,max,buf) end end
    end); return buf
end
local function runScan(obj,depth,label)
    sLog.clear(); sLog.header(label); setSt("Scanning "..label.."...")
    task.spawn(function()
        local buf={}; local ok,err=pcall(function() sTree(obj,0,depth,buf) end)
        if not ok then sLog.add("[ERR] "..tostring(err)); sLog.flush(); setSt("Error"); return end
        local i=1; while i<=#buf do for j=i,math.min(i+199,#buf) do sLog.add(buf[j]) end; sLog.flush(); i=i+200; if i<=#buf then task.wait() end end
        sLog.flush(); setSt(label..": "..#buf.." lines")
    end)
end
bRS.MouseButton1Click:Connect(function() runScan(RS,6,"RS") end)
bWS.MouseButton1Click:Connect(function() runScan(WS,4,"WS") end)
bUID.MouseButton1Click:Connect(function()
    sLog.clear(); sLog.header("UUID Scan"); setSt("Scanning...")
    task.spawn(function()
        local n=0; local buf={}
        local function s(obj,path,d) if d>8 then return end; local nm=""; pcall(function() nm=obj.Name end); if #nm==36 and nm:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then buf[#buf+1]="  "..path; n=n+1 end; pcall(function() for _,c in ipairs(obj:GetChildren()) do local cn=""; pcall(function() cn=c.Name end); s(c,path.."/"..cn,d+1) end end) end
        pcall(function() s(WS,"WS",0); s(RS,"RS",0) end)
        for _,l in ipairs(buf) do sLog.add(l) end; sLog.flush(); setSt("UUIDs: "..n)
    end)
end)
bPlt.MouseButton1Click:Connect(function()
    sLog.clear(); sLog.header("Plots"); setSt("...")
    task.spawn(function()
        local pl=WS:FindFirstChild("Plots"); if not pl then sLog.add("Plots not found"); sLog.flush(); return end
        for _,p in ipairs(pl:GetChildren()) do
            sLog.add("[Plot] "..p.Name); pcall(function() for k,v in pairs(p:GetAttributes()) do sLog.add("  "..k.."="..tostring(v)) end end)
            pcall(function() for _,c in ipairs(p:GetChildren()) do local info="  ["..c.ClassName.."] "..c.Name; if c.Name=="Sim" then local n=0; for _,x in ipairs(c:GetChildren()) do if #x.Name==36 then n=n+1 end end; info=info.." ("..n.." UUIDs)" end; sLog.add(info) end end)
        end; sLog.flush(); setSt("Plots done")
    end)
end)
local function snapObj(r) local s={}; local function w(o,p) local cn=""; pcall(function() cn=o.ClassName end); s[p]=cn; pcall(function() for k,v in pairs(o:GetAttributes()) do s[p.."@"..k]=tostring(v) end end); pcall(function() for _,c in ipairs(o:GetChildren()) do local nm=""; pcall(function() nm=c.Name end); w(c,p.."/"..nm) end end) end; w(r,""); return s end
bSnap.MouseButton1Click:Connect(function() task.spawn(function() diffSnap={ws=snapObj(WS),rs=snapObj(RS)}; sLog.add("[OK] Snapshot taken"); sLog.flush(); setSt("Snapshot OK") end) end)
bDiff.MouseButton1Click:Connect(function()
    if not diffSnap then sLog.add("Take snapshot first"); sLog.flush(); return end
    sLog.clear(); sLog.header("Diff")
    task.spawn(function()
        local a,r,c=0,0,0; local ws2,rs2=snapObj(WS),snapObj(RS)
        local function df(old,nw,lb) for k,v in pairs(nw) do if not old[k] then sLog.add("[+] "..lb..k); a=a+1 elseif old[k]~=v then sLog.add("[~] "..lb..k); c=c+1 end end; for k in pairs(old) do if not nw[k] then sLog.add("[-] "..lb..k); r=r+1 end end end
        df(diffSnap.ws,ws2,"WS/"); df(diffSnap.rs,rs2,"RS/"); sLog.flush(); setSt("+"..a.." ~"..c.." -"..r)
    end)
end)
bJSON.MouseButton1Click:Connect(function()
    task.spawn(function()
        local p={"["}; local n=0
        local function s(o,d) if d>4 then return end; local a={}; pcall(function() for k,v in pairs(o:GetAttributes()) do a[#a+1]='"'..k..'":"'..tostring(v)..'"' end end); local cn=""; pcall(function() cn=o.ClassName end); local nm=""; pcall(function() nm=o.Name end); p[#p+1]='{"n":"'..nm..'","c":"'..cn..'","a":{'..table.concat(a,",").."}}"; n=n+1; pcall(function() for _,c in ipairs(o:GetChildren()) do s(c,d+1) end end) end
        pcall(function() s(RS,0) end); p[#p+1]="]"; pcall(setclipboard,table.concat(p,"\n")); sLog.add("[JSON] "..n.." nodes copied"); sLog.flush(); setSt("JSON: "..n)
    end)
end)
bCpS.MouseButton1Click:Connect(function() sLog.copy() end)
bClS.MouseButton1Click:Connect(function() sLog.clear() end)

local simOn,simConn,simCnt=false,nil,0
simBtn.MouseButton1Click:Connect(function()
    simOn=not simOn
    if simOn then
        pcall(function() simBtn.Text="Watch Sim: ON"; simBtn.BackgroundColor3=Color3.fromRGB(12,68,36) end); simCnt=0
        task.spawn(function()
            local watched=nil; while simOn do task.wait(2)
                pcall(function()
                    local pl=WS:FindFirstChild("Plots"); if not pl then return end
                    for _,p in ipairs(pl:GetChildren()) do
                        if tostring(p:GetAttribute("USERID"))==tostring(LP.UserId) then
                            local sim=p:FindFirstChild("Sim"); if not sim or sim==watched then return end
                            if simConn then simConn:Disconnect() end; watched=sim; simCnt=0
                            for _,c in ipairs(sim:GetChildren()) do if #c.Name==36 then simCnt=simCnt+1 end end
                            simConn=sim.ChildAdded:Connect(function(child)
                                if #child.Name==36 and child.Name:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then
                                    simCnt=simCnt+1; pcall(function() simLbl.Text="UUIDs: "..simCnt end); sLog.add("[NEW UUID] "..child.Name); sLog.flush()
                                end
                            end); pcall(function() simLbl.Text="Watching. UUIDs: "..simCnt end)
                        end
                    end
                end)
            end; if simConn then pcall(function() simConn:Disconnect() end); simConn=nil end
        end)
    else
        pcall(function() simBtn.Text="Watch Sim: OFF"; simBtn.BackgroundColor3=Color3.fromRGB(26,26,44); simLbl.Text="" end)
        if simConn then pcall(function() simConn:Disconnect() end); simConn=nil end; simOn=false
    end
end)

-- ================================================================
-- TAB 2: HOOK
-- ================================================================
local hP=mkTab("Hook")

-- ── Top control bar ──────────────────────────────────────────────
local hRow=mkRow(hP,4,28)
local hCli  =hRow("Watch Client",Color3.fromRGB(90,30,30))
local hFire =hRow("Hook Fire",   Color3.fromRGB(50,22,105))
local hInv  =hRow("Hook Invoke", Color3.fromRGB(22,52,105))
local hStop =hRow("Stop All",    Color3.fromRGB(72,16,16))
local hDbg  =hRow("Debug: OFF",  Color3.fromRGB(38,38,18))
local hTest =hRow("Test",        Color3.fromRGB(18,58,38))
local hClrAll=hRow("Clr Calls",  Color3.fromRGB(50,10,10))

-- ── Left panel: call list ────────────────────────────────────────
local LEFT_W=0.30
local leftPanel=mkF(hP,BG2,UDim2.new(LEFT_W,-4,1,-40),UDim2.new(0,4,0,36),6)

-- header strip
local lHdr=mkF(leftPanel,BG3,UDim2.new(1,0,0,26),UDim2.new(0,0,0,0),6)
mkF(lHdr,BG3,UDim2.new(1,0,0.5,0),UDim2.new(0,0,0.5,0))  -- flatten bottom corners
mkL(lHdr,"CALLS",UDim2.new(0.6,0,1,0),UDim2.new(0,8,0,0),TXT1,Enum.Font.GothamBold,10)
local callCountL=mkL(lHdr,"0",UDim2.new(0.4,0,1,0),UDim2.new(0.6,0,0,0),GREEN,Enum.Font.GothamBold,10)
callCountL.TextXAlignment=Enum.TextXAlignment.Right

-- scrolling call list
local callSF=mkSF(leftPanel,UDim2.new(1,-2,1,-26),UDim2.new(0,1,0,26))
local callLL=Instance.new("UIListLayout",callSF)
callLL.Padding=UDim.new(0,1); callLL.SortOrder=Enum.SortOrder.LayoutOrder

-- ── Right panel: code viewer ─────────────────────────────────────
local rightPanel=mkF(hP,BG,UDim2.new(1-LEFT_W,-8,1,-40),UDim2.new(LEFT_W,4,0,36),6)

-- header strip
local rHdr=mkF(rightPanel,BG2,UDim2.new(1,0,0,26),UDim2.new(0,0,0,0),6)
mkF(rHdr,BG2,UDim2.new(1,0,0.5,0),UDim2.new(0,0,0.5,0))
local codeTitle=mkL(rHdr,"← click a call to view code",UDim2.new(1,-100,1,0),UDim2.new(0,8,0,0),CYAN,Enum.Font.GothamBold,11)
-- type badge
local typeBadge=Instance.new("TextLabel",rHdr)
typeBadge.Size=UDim2.new(0,92,0,18); typeBadge.Position=UDim2.new(1,-96,0.5,-9)
typeBadge.BackgroundColor3=BG3; typeBadge.TextColor3=AMBER; typeBadge.Font=Enum.Font.GothamBold; typeBadge.TextSize=9; typeBadge.Text=""; typeBadge.BorderSizePixel=0; typeBadge.RichText=false; typeBadge.TextXAlignment=Enum.TextXAlignment.Center
Instance.new("UICorner",typeBadge).CornerRadius=UDim.new(0,4)

-- code scroll area
local codeSF=mkSF(rightPanel,UDim2.new(1,-4,1,-90),UDim2.new(0,2,0,28))
local codeTxt=Instance.new("TextLabel",codeSF)
codeTxt.Size=UDim2.new(1,-8,0,200); codeTxt.Position=UDim2.new(0,4,0,4)
codeTxt.BackgroundTransparency=1; codeTxt.TextColor3=Color3.fromRGB(180,225,175)
codeTxt.Font=Enum.Font.Code; codeTxt.TextSize=11
codeTxt.TextXAlignment=Enum.TextXAlignment.Left; codeTxt.TextYAlignment=Enum.TextYAlignment.Top
codeTxt.TextWrapped=true; codeTxt.RichText=false; codeTxt.Text="-- select a call from the left panel"

-- ── Action buttons row 1 ─────────────────────────────────────────
local actRow1=mkF(rightPanel,BG2,UDim2.new(1,-4,0,28),UDim2.new(0,2,1,-58),5)
local arLL1=Instance.new("UIListLayout",actRow1); arLL1.FillDirection=Enum.FillDirection.Horizontal; arLL1.Padding=UDim.new(0,4); arLL1.VerticalAlignment=Enum.VerticalAlignment.Center
local arPad=Instance.new("UIPadding",actRow1); arPad.PaddingLeft=UDim.new(0,6); arPad.PaddingTop=UDim.new(0,4)
local function arBtn1(t,bg) local b=mkB(actRow1,t,bg,UDim2.new(0,0,0,22)); b.AutomaticSize=Enum.AutomaticSize.X; local p=Instance.new("UIPadding",b); p.PaddingLeft=UDim.new(0,8); p.PaddingRight=UDim.new(0,8); return b end
local bCopyCode  =arBtn1("Copy Code",   Color3.fromRGB(12,55,55))
local bCopyRemote=arBtn1("Copy Remote", Color3.fromRGB(12,44,72))
local bCopyArgs  =arBtn1("Copy Args",   Color3.fromRGB(14,46,38))
local bBlock     =arBtn1("Block: OFF",  Color3.fromRGB(52,16,16))
local bRunCode   =arBtn1("Run Code",    Color3.fromRGB(20,68,30))
local bGetScript =arBtn1("Get Script",  Color3.fromRGB(52,40,10))

-- ── Action buttons row 2 ─────────────────────────────────────────
local actRow2=mkF(rightPanel,BG2,UDim2.new(1,-4,0,26),UDim2.new(0,2,1,-28),5)
local arLL2=Instance.new("UIListLayout",actRow2); arLL2.FillDirection=Enum.FillDirection.Horizontal; arLL2.Padding=UDim.new(0,4); arLL2.VerticalAlignment=Enum.VerticalAlignment.Center
local arPad2=Instance.new("UIPadding",actRow2); arPad2.PaddingLeft=UDim.new(0,6); arPad2.PaddingTop=UDim.new(0,3)
local function arBtn2(t,bg) local b=mkB(actRow2,t,bg,UDim2.new(0,0,0,20)); b.AutomaticSize=Enum.AutomaticSize.X; local p=Instance.new("UIPadding",b); p.PaddingLeft=UDim.new(0,8); p.PaddingRight=UDim.new(0,8); return b end
local bExcludeI =arBtn2("Exclude (i)", Color3.fromRGB(52,42,12))
local bExcludeN =arBtn2("Exclude (n)", Color3.fromRGB(42,30,10))
local bBlockI   =arBtn2("Block (i)",   Color3.fromRGB(72,16,16))
local bBlockN   =arBtn2("Block (n)",   Color3.fromRGB(55,12,12))
local bFuncInfo =arBtn2("Func Info",   Color3.fromRGB(30,55,80))
local bModArgs  =arBtn2("Mod Args",    Color3.fromRGB(18,55,30))

-- ── Helper: generate SimpleSpy-style code ───────────────────────
local function genCode(entry)
    if not entry then return "-- no call selected" end
    local lines={
        "-- Script generated by Kelza Spy",
        "",
        "local args = {"
    }
    for i,v in ipairs(entry.a) do
        local vs
        if type(v)=="string" then
            vs='"'..v:gsub('"','\\"')..'"'
        elseif type(v)=="number" or type(v)=="boolean" then
            vs=tostring(v)
        elseif type(v)=="table" then
            vs="{--[[table]]}"
        else
            vs="--[["..type(v).."]] "..tostring(v)
        end
        lines[#lines+1]="    ["..i.."] = "..vs..","
    end
    lines[#lines+1]="}"
    lines[#lines+1]=""
    -- remote path
    local path='game:GetService("ReplicatedStorage").events.'..entry.n
    if entry.t=="F" then
        lines[#lines+1]=path..":FireServer(table.unpack(args))"
    elseif entry.t=="I" then
        lines[#lines+1]=path..":InvokeServer(table.unpack(args))"
    elseif entry.t=="C" then
        lines[#lines+1]="-- OnClientEvent: "..entry.n
        lines[#lines+1]=path..".OnClientEvent:Connect(function(...) end)"
    end
    return table.concat(lines,"\n")
end

-- ── Show call in code viewer ─────────────────────────────────────
local function showCall(entry)
    selCall=entry
    if not entry then return end
    local code=genCode(entry)
    local lineCount=0; for _ in code:gmatch("\n") do lineCount=lineCount+1 end; lineCount=lineCount+1
    local h=lineCount*13+8
    pcall(function()
        codeTitle.Text=entry.n
        if entry.t=="F" then typeBadge.Text="FireServer"; typeBadge.BackgroundColor3=PURP
        elseif entry.t=="I" then typeBadge.Text="InvokeServer"; typeBadge.BackgroundColor3=BLUE
        else typeBadge.Text="OnClientEvent"; typeBadge.BackgroundColor3=GREEN end
        typeBadge.TextColor3=TXT
        codeTxt.Size=UDim2.new(1,-8,0,h); codeTxt.Text=code
        codeSF.CanvasSize=UDim2.new(0,0,0,h+8); codeSF.CanvasPosition=Vector2.new(0,0)
        -- update block button state
        local c2=cfg(entry.n)
        bBlock.Text=c2.block and "Block: ON" or "Block: OFF"
        bBlock.BackgroundColor3=c2.block and Color3.fromRGB(140,22,22) or Color3.fromRGB(52,16,16)
    end)
end

-- ── Add item to call list ────────────────────────────────────────
local function addCallItem(entry)
    if excludeSet[entry.n] then return end
    -- prepend to callLog
    table.insert(callLog,1,entry)
    if #callLog>MAX_CALLS then table.remove(callLog) end

    -- icon + color by type
    local icon=entry.t=="F" and "▶" or entry.t=="I" and "◆" or "◀"
    local iconClr=entry.t=="F" and PURP or entry.t=="I" and BLUE or GREEN

    -- create list item
    local it=Instance.new("TextButton",callSF)
    it.Size=UDim2.new(1,0,0,28); it.BackgroundColor3=BG3; it.BorderSizePixel=0; it.RichText=false; it.Text=""
    it.LayoutOrder=0  -- newest on top
    Instance.new("UICorner",it).CornerRadius=UDim.new(0,4)

    -- icon label
    local iconL=Instance.new("TextLabel",it); iconL.Text=icon; iconL.Size=UDim2.new(0,18,1,0); iconL.Position=UDim2.new(0,4,0,0); iconL.BackgroundTransparency=1; iconL.TextColor3=iconClr; iconL.Font=Enum.Font.GothamBold; iconL.TextSize=11; iconL.RichText=false; iconL.TextXAlignment=Enum.TextXAlignment.Center

    -- remote name
    local nameL=Instance.new("TextLabel",it); nameL.Text=entry.n; nameL.Size=UDim2.new(1,-56,1,0); nameL.Position=UDim2.new(0,24,0,0); nameL.BackgroundTransparency=1; nameL.TextColor3=TXT; nameL.Font=Enum.Font.Gotham; nameL.TextSize=10; nameL.RichText=false; nameL.TextXAlignment=Enum.TextXAlignment.Left; nameL.TextTruncate=Enum.TextTruncate.AtEnd

    -- arg count badge
    local cntBg=Instance.new("Frame",it); cntBg.Size=UDim2.new(0,26,0,16); cntBg.Position=UDim2.new(1,-30,0.5,-8); cntBg.BackgroundColor3=BG2; cntBg.BorderSizePixel=0; Instance.new("UICorner",cntBg).CornerRadius=UDim.new(0,3)
    local cntL=Instance.new("TextLabel",cntBg); cntL.Size=UDim2.new(1,0,1,0); cntL.BackgroundTransparency=1; cntL.TextColor3=TXT2; cntL.Font=Enum.Font.GothamBold; cntL.TextSize=9; cntL.Text="#"..#entry.a; cntL.RichText=false; cntL.TextXAlignment=Enum.TextXAlignment.Center

    -- push existing items down
    for _,c in ipairs(callSF:GetChildren()) do
        if c:IsA("TextButton") then pcall(function() c.LayoutOrder=c.LayoutOrder+1 end) end
    end

    -- click to view
    it.MouseButton1Click:Connect(function()
        for _,c in ipairs(callSF:GetChildren()) do
            if c:IsA("TextButton") then pcall(function() c.BackgroundColor3=BG3 end) end
        end
        pcall(function() it.BackgroundColor3=Color3.fromRGB(28,28,70) end)
        showCall(entry)
    end)

    -- update count + scroll to top
    local cnt=0
    for _,c in ipairs(callSF:GetChildren()) do if c:IsA("TextButton") then cnt=cnt+1 end end
    pcall(function()
        callSF.CanvasSize=UDim2.new(0,0,0,cnt*29+4)
        callSF.CanvasPosition=Vector2.new(0,0)
        callCountL.Text=tostring(cnt)
    end)
end

-- ── UI drain loop ────────────────────────────────────────────────
task.spawn(function()
    while WIN.Parent do
        task.wait(0.15)
        if #hookQueue>0 then
            local batch=hookQueue; hookQueue={}
            for _,e in ipairs(batch) do
                pcall(function()
                    if e[1]=="F" or e[1]=="I" or e[1]=="C" then
                        addCallItem({n=e.n, t=e[1], a=e.a or {}, ts=os.clock()})
                    end
                end)
            end
        end
    end
end)

-- ── Action button logic ──────────────────────────────────────────
bCopyCode.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    pcall(setclipboard,genCode(selCall)); setSt("Code copied!")
end)
bCopyRemote.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    pcall(setclipboard,'game:GetService("ReplicatedStorage").events.'..selCall.n)
    setSt("Remote path copied!")
end)
bCopyArgs.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    pcall(setclipboard,"{"..a2s(selCall.a).."}"); setSt("Args copied!")
end)
bBlock.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    local c2=cfg(selCall.n); c2.block=not c2.block
    pcall(function() bBlock.Text=c2.block and "Block: ON" or "Block: OFF"; bBlock.BackgroundColor3=c2.block and Color3.fromRGB(140,22,22) or Color3.fromRGB(52,16,16) end)
    setSt((c2.block and "Blocked: " or "Unblocked: ")..selCall.n)
end)
bRunCode.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    local code=genCode(selCall)
    local ok,fn=pcall(loadstring,code)
    if ok and type(fn)=="function" then
        local ok2,err=pcall(fn); setSt(ok2 and "Ran!" or "Error: "..tostring(err))
    else setSt("loadstring failed") end
end)
bGetScript.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    -- show decompile of any script that calls this remote
    local rn=selCall.n; local found={}
    local function scanScripts(o,depth)
        if depth>8 then return end
        pcall(function()
            if o:IsA("LocalScript") or o:IsA("ModuleScript") or o:IsA("Script") then
                local ok,src=pcall(decompile,o)
                if ok and type(src)=="string" and src:find(rn,1,true) then found[#found+1]=o.Name end
            end
            for _,c in ipairs(o:GetChildren()) do scanScripts(c,depth+1) end
        end)
    end
    task.spawn(function()
        pcall(function() scanScripts(game,0) end)
        if #found>0 then
            local msg="Scripts referencing "..rn..":\n"..table.concat(found,"\n")
            local lc=0; for _ in msg:gmatch("\n") do lc=lc+1 end; lc=lc+1
            local h=lc*13+8
            pcall(function() codeTxt.Size=UDim2.new(1,-8,0,h); codeTxt.Text=msg; codeSF.CanvasSize=UDim2.new(0,0,0,h+8) end)
            setSt("Found: "..#found.." scripts")
        else setSt("No scripts found for: "..rn) end
    end)
end)
bExcludeI.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    local n=selCall.n; excludeSet[n]=true; setSt("Excluded: "..n)
    -- remove existing items with this name from the list
    for _,c in ipairs(callSF:GetChildren()) do if c:IsA("TextButton") and c.Name==n then pcall(function() c:Destroy() end) end end
end)
bExcludeN.MouseButton1Click:Connect(function()
    -- exclude all currently visible remote names
    for _,c in ipairs(callSF:GetChildren()) do if c:IsA("TextButton") then excludeSet[c.Name]=true end end
    for _,c in ipairs(callSF:GetChildren()) do if c:IsA("TextButton") then pcall(function() c:Destroy() end) end end
    setSt("Excluded all visible")
end)
bBlockI.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    local c2=cfg(selCall.n); c2.block=true
    pcall(function() bBlock.Text="Block: ON"; bBlock.BackgroundColor3=Color3.fromRGB(140,22,22) end)
    setSt("Blocked: "..selCall.n)
end)
bBlockN.MouseButton1Click:Connect(function()
    -- block all currently visible remotes
    for _,c in ipairs(callSF:GetChildren()) do if c:IsA("TextButton") then cfg(c.Name).block=true end end
    setSt("Blocked all visible")
end)
bFuncInfo.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    local info={"-- Function Info: "..selCall.n,"","Args ("..#selCall.a.."):"	}
    for i,v in ipairs(selCall.a) do
        local t=type(v); local vs=tostring(v)
        if t=="string" then
            if #vs==36 and vs:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then info[#info+1]="  ["..i.."] string (UUID): "..vs
            else info[#info+1]="  ["..i.."] string["..#vs.."]: "..vs:sub(1,60)..(#vs>60 and "..." or "") end
        else info[#info+1]="  ["..i.."] "..t..": "..vs end
    end
    info[#info+1]=""; info[#info+1]="Rate: "..freq(selCall.n).r.."/s"
    info[#info+1]="Block: "..tostring(cfg(selCall.n).block)
    local code=table.concat(info,"\n"); local lc=0; for _ in code:gmatch("\n") do lc=lc+1 end; lc=lc+1
    local h=lc*13+8
    pcall(function() codeTitle.Text="Info: "..selCall.n; typeBadge.Text="Info"; typeBadge.BackgroundColor3=AMBER; codeTxt.Size=UDim2.new(1,-8,0,h); codeTxt.Text=code; codeSF.CanvasSize=UDim2.new(0,0,0,h+8) end)
end)
bModArgs.MouseButton1Click:Connect(function()
    if not selCall then setSt("Select a call first"); return end
    cfg(selCall.n).mod=selCall.a; setSt("Mod set from call: "..selCall.n)
end)

-- forward declarations (defined later after UI)
local installNC, removeNC

-- Clear all calls
local function doClearCalls()
    callLog={}; selCall=nil
    for _,c in ipairs(callSF:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
    pcall(function() callSF.CanvasSize=UDim2.new(0,0,0,0); callCountL.Text="0"; codeTitle.Text="← click a call to view code"; typeBadge.Text=""; codeTxt.Text="-- cleared" end)
    setSt("Calls cleared")
end
hClrAll.MouseButton1Click:Connect(doClearCalls)

-- Test hook (shows result in code viewer)
local function doTestHook()
    local lines={"-- Hook Diagnostics",""}
    local function chk(n,fn) local ok,r=pcall(fn); lines[#lines+1]=(ok and r and "[OK] " or "[--] ")..n end
    chk("getrawmetatable",function() return type(getrawmetatable(game))=="table" end)
    chk("setreadonly",function() local m=getrawmetatable(game); setreadonly(m,false); setreadonly(m,true); return true end)
    chk("getnamecallmethod",function() return type(getnamecallmethod)=="function" end)
    lines[#lines+1]="hook installed: "..tostring(namecallInstalled)
    local cc=0; for _ in pairs(remoteCache) do cc=cc+1 end; lines[#lines+1]="cache size: "..cc
    local evs=RS:FindFirstChild("events"); local rem=evs and evs:FindFirstChildWhichIsA("RemoteEvent")
    if rem then
        lines[#lines+1]="test remote: "..rem.Name; lines[#lines+1]="in cache: "..tostring(remoteCache[rem]~=nil)
        if not namecallInstalled then installNC() end
        if namecallInstalled then
            local prev=hookFire; hookFire=true
            pcall(function() rem:FireServer("__TEST__") end); task.wait(0.3); hookFire=prev
            if not hookFire and not hookInvoke and not hookDebug then removeNC() end
            lines[#lines+1]="→ TEST call should appear in list above"
        end
    else lines[#lines+1]="No RemoteEvent found - run Scan RS first" end
    local code=table.concat(lines,"\n"); local lc=0; for _ in code:gmatch("\n") do lc=lc+1 end; lc=lc+1
    local h=lc*13+8
    pcall(function() codeTitle.Text="Diagnostics"; typeBadge.Text="TEST"; typeBadge.BackgroundColor3=AMBER; codeTxt.Size=UDim2.new(1,-8,0,h); codeTxt.Text=code; codeSF.CanvasSize=UDim2.new(0,0,0,h+8); codeSF.CanvasPosition=Vector2.new(0,0) end)
end
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
    if not oldNamecall then pcall(setreadonly,mt,true); setSt("[ERR] no __namecall"); return false end

    buildRemoteCache()
    local cc=0; for _ in pairs(remoteCache) do cc=cc+1 end
    setSt("hook ok, "..cc.." cached")

    rawset(mt,"__namecall",function(self,...)
        local method=""
        if getnamecallmethod then
            local m; pcall(function() m=getnamecallmethod() end)
            if type(m)=="string" then method=m end
        end
        if method=="" then local a=table.pack(...); if type(a[a.n])=="string" then method=a[a.n] end end

        local cached=remoteCache[self]

        if cached then
            local capF=hookFire  and cached.isRE and method=="FireServer"
            local capI=hookInvoke and cached.isRF and method=="InvokeServer"
            local doD =hookDebug  and method~=""

            if capF or capI then
                local args=table.pack(...)
                if method~="" and args[args.n]==method then args.n=args.n-1 end
                local clean={}; for i=1,args.n do clean[i]=args[i] end
                bump(cached.nm); ensureR(cached.nm); remLastArgs[cached.nm]=clean; hist(cached.nm,clean)
                local c2=cfg(cached.nm); local pass=true
                if c2.filt and c2.filt~="" then
                    pass=false; for _,v in ipairs(clean) do if tostring(v):lower():find(c2.filt:lower(),1,true) then pass=true; break end end
                end
                if pass then hookQueue[#hookQueue+1]={[1]=capF and "F" or "I", n=cached.nm, a=clean} end
                if c2.block then return end
                if c2.mod then return oldNamecall(self,table.unpack(c2.mod)) end
            elseif doD then
                hookQueue[#hookQueue+1]={[1]="D", m=method, n=cached.nm}
            end
        elseif hookDebug and method~="" then
            local n2="?"; pcall(function() n2=self.Name end)
            hookQueue[#hookQueue+1]={[1]="D", m=method, n=n2}
        end

        return oldNamecall(self,...)
    end)

    pcall(setreadonly,mt,true); namecallInstalled=true; return true
end

removeNC = function()
    if not namecallInstalled then return end
    local ok,mt=pcall(getrawmetatable,game)
    if ok and mt then pcall(setreadonly,mt,false); rawset(mt,"__namecall",oldNamecall); pcall(setreadonly,mt,true) end
    oldNamecall=nil; namecallInstalled=false; hookFire=false; hookInvoke=false; hookDebug=false
    pcall(function() hFire.Text="Hook Fire"; hFire.BackgroundColor3=Color3.fromRGB(50,22,105); hInv.Text="Hook Invoke"; hInv.BackgroundColor3=Color3.fromRGB(22,52,105) end)
    setSt("Hook removed")
end

hCli.MouseButton1Click:Connect(function()
    if #clientConns>0 then
        for _,c in ipairs(clientConns) do pcall(function() c:Disconnect() end) end; clientConns={}; clientLastLog={}
        pcall(function() hCli.Text="Watch Client"; hCli.BackgroundColor3=Color3.fromRGB(90,30,30) end)
        setSt("Watch stopped"); return
    end
    local evs=RS:FindFirstChild("events"); if not evs then setSt("[ERR] events folder not found"); return end
    local n=0
    for _,r in ipairs(evs:GetChildren()) do if r:IsA("RemoteEvent") then
        local rn=r.Name; ensureR(rn); remoteCache[r]={isRE=true,isRF=false,nm=rn}
        local conn=r.OnClientEvent:Connect(function(...)
            bump(rn); local now=tick(); if now-(clientLastLog[rn] or 0)<0.3 then return end; clientLastLog[rn]=now
            hookQueue[#hookQueue+1]={[1]="C",n=rn,a={...}}
        end); clientConns[#clientConns+1]=conn; n=n+1
    end end
    pcall(function() hCli.Text="STOP Watch"; hCli.BackgroundColor3=Color3.fromRGB(140,30,30) end); setSt("Watching "..n.." remotes")
end)
hFire.MouseButton1Click:Connect(function()
    if hookFire then hookFire=false; pcall(function() hFire.Text="Hook Fire"; hFire.BackgroundColor3=Color3.fromRGB(50,22,105) end); if not hookInvoke and not hookDebug then removeNC() end; setSt("FireServer OFF"); return end
    if installNC() then hookFire=true; pcall(function() hFire.Text="STOP Fire"; hFire.BackgroundColor3=Color3.fromRGB(115,28,115) end); setSt("Hooking FireServer...") end
end)
hInv.MouseButton1Click:Connect(function()
    if hookInvoke then hookInvoke=false; pcall(function() hInv.Text="Hook Invoke"; hInv.BackgroundColor3=Color3.fromRGB(22,52,105) end); if not hookFire and not hookDebug then removeNC() end; setSt("InvokeServer OFF"); return end
    if installNC() then hookInvoke=true; pcall(function() hInv.Text="STOP Invoke"; hInv.BackgroundColor3=Color3.fromRGB(22,88,130) end); setSt("Hooking InvokeServer...") end
end)
hStop.MouseButton1Click:Connect(function()
    for _,c in ipairs(clientConns) do pcall(function() c:Disconnect() end) end; clientConns={}; clientLastLog={}
    pcall(function() hCli.Text="Watch Client"; hCli.BackgroundColor3=Color3.fromRGB(90,30,30) end)
    hookFire=false; hookInvoke=false; hookDebug=false; removeNC(); setSt("All stopped")
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
local spP=mkTab("Spam"); local spLog=mkLog(spP,UDim2.new(1,-8,1,-234),UDim2.new(0,4,0,230))
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
local spSt=mkB(spCfg,"Start",Color3.fromRGB(28,90,34),UDim2.new(0,55,0,22),UDim2.new(0,96,0,56))
local spSp=mkB(spCfg,"Stop",Color3.fromRGB(90,28,28),UDim2.new(0,50,0,22),UDim2.new(0,156,0,56))
local spRL=mkL(spCfg,"--",UDim2.new(0,80,0,13),UDim2.new(0,212,0,60),GREEN,Enum.Font.GothamBold,10)
mkF(spCfg,LINE,UDim2.new(1,-8,0,1),UDim2.new(0,4,0,84))
mkL(spCfg,"Multi (name|args|delay per line):",UDim2.new(1,-8,0,12),UDim2.new(0,4,0,88),TXT2,Enum.Font.GothamBold,9)
local spMT=mkTB(spCfg,'collect|"uuid"|0.5\nuploadAll||5',UDim2.new(1,-8,0,48),UDim2.new(0,4,0,102),true)
local spMS=mkB(spCfg,"Multi Start",Color3.fromRGB(22,80,52),UDim2.new(0,85,0,22),UDim2.new(0,4,0,154))
local spMX=mkB(spCfg,"Multi Stop",Color3.fromRGB(80,28,28),UDim2.new(0,82,0,22),UDim2.new(0,94,0,154))
mkF(spCfg,LINE,UDim2.new(1,-8,0,1),UDim2.new(0,4,0,182))
mkL(spCfg,"Preset name:",UDim2.new(0,80,0,12),UDim2.new(0,4,0,186),TXT2,Enum.Font.GothamBold,9)
local spPN=mkTB(spCfg,"name",UDim2.new(0,100,0,22),UDim2.new(0,4,0,200))
local spSv=mkB(spCfg,"Save",Color3.fromRGB(50,70,22),UDim2.new(0,48,0,22),UDim2.new(0,108,0,200))
local spLd=mkB(spCfg,"Load",Color3.fromRGB(22,52,76),UDim2.new(0,48,0,22),UDim2.new(0,160,0,200))
local spLs=mkB(spCfg,"List",Color3.fromRGB(52,46,16),UDim2.new(0,44,0,22),UDim2.new(0,212,0,200))
local presets={}
spSv.MouseButton1Click:Connect(function() local n=spPN.Text:match("^%s*(.-)%s*$"); if n~="" then presets[n]={r=spRem.Text,a=spArgs.Text,d=spDly.Text,e=spIsE,m=spMT.Text}; spLog.add("[SAVE] "..n); spLog.flush() end end)
spLd.MouseButton1Click:Connect(function() local n=spPN.Text:match("^%s*(.-)%s*$"); local p=presets[n]; if not p then spLog.add("[!] "..n); spLog.flush(); return end; pcall(function() spRem.Text=p.r or ""; spArgs.Text=p.a or ""; spDly.Text=p.d or "0.5"; spIsE=p.e~=false; spMT.Text=p.m or "" end); spLog.add("[LOAD] "..n); spLog.flush() end)
spLs.MouseButton1Click:Connect(function() spLog.header("Presets"); local n=0; for k in pairs(presets) do spLog.add("  "..k); n=n+1 end; if n==0 then spLog.add("  (none)") end; spLog.flush() end)
spSt.MouseButton1Click:Connect(function()
    if spActive then return end; local name=spRem.Text:match("^%s*(.-)%s*$"); if name=="" then spLog.add("[!] Enter name"); spLog.flush(); return end
    local dly=tonumber(spDly.Text) or 0.5; local raw=spArgs.Text; spActive=true; spCnt=0; spLog.header("Spam: "..name)
    task.spawn(function() local t0=tick(); while spActive do
        local ev=RS:FindFirstChild("events"); if not ev then break end
        local r=ev:FindFirstChild(name); if not r then spLog.add("[!] not found"); spLog.flush(); spActive=false; break end
        if spIsE and r:IsA("RemoteEvent") then pcall(function() r:FireServer(table.unpack(raw~="" and parseA(raw) or {})) end)
        else pcall(function() r:InvokeServer(table.unpack(raw~="" and parseA(raw) or {})) end) end
        spCnt=spCnt+1; local e=tick()-t0; pcall(function() spRL.Text=(e>0 and math.floor(spCnt/e*10)/10 or 0).."/s" end); task.wait(dly)
    end; spLog.add("[STOP] "..spCnt); spLog.flush() end)
end)
spSp.MouseButton1Click:Connect(function() spActive=false end)
spMS.MouseButton1Click:Connect(function()
    if multiActive then return end; local rems={}
    for line in (spMT.Text.."\n"):gmatch("([^\n]*)\n") do local pp={}; for p in (line.."|"):gmatch("([^|]*)|") do pp[#pp+1]=p end; local n=pp[1] and pp[1]:match("^%s*(.-)%s*$") or ""; if n~="" then rems[#rems+1]={n=n,a=pp[2] or "",d=tonumber(pp[3]) or 1} end end
    if #rems==0 then spLog.add("[!] empty"); spLog.flush(); return end
    multiActive=true; spLog.header("Multi: "..#rems)
    for _,r in ipairs(rems) do task.spawn(function()
        local ev=RS:FindFirstChild("events"); if not ev then return end; local rem=ev:FindFirstChild(r.n); if not rem then return end
        while multiActive do
            if rem:IsA("RemoteEvent") then pcall(function() rem:FireServer(table.unpack(r.a~="" and parseA(r.a) or {})) end)
            else pcall(function() rem:InvokeServer(table.unpack(r.a~="" and parseA(r.a) or {})) end) end; task.wait(r.d)
        end
    end) end; spLog.add("[ON]"); spLog.flush()
end)
spMX.MouseButton1Click:Connect(function() multiActive=false; spLog.add("[STOP] multi"); spLog.flush() end)

-- ================================================================
-- TAB 4: DECOMPILE
-- ================================================================
local dP=mkTab("Decompile")
local dLeft=mkF(dP,BG2,UDim2.new(0.33,-5,1,-4),UDim2.new(0,2,0,2),7)
local dHdr=mkF(dLeft,BG3,UDim2.new(1,0,0,28),UDim2.new(0,0,0,0),7); mkF(dHdr,BG3,UDim2.new(1,0,0.5,0),UDim2.new(0,0,0.5,0))
mkL(dHdr,"Scripts",UDim2.new(1,-65,1,0),UDim2.new(0,6,0,0),TXT,Enum.Font.GothamBold,11)
local dScanB=mkB(dHdr,"Scan",Color3.fromRGB(18,48,95),UDim2.new(0,50,0,22),UDim2.new(1,-56,0,3))
local dFilt=mkTB(dLeft,"filter...",UDim2.new(1,-6,0,22),UDim2.new(0,3,0,32))
local dList=mkSF(dLeft,UDim2.new(1,-4,1,-60),UDim2.new(0,2,0,58)); Instance.new("UIListLayout",dList).Padding=UDim.new(0,2)
local dRight=mkF(dP,BG,UDim2.new(0.67,-5,1,-4),UDim2.new(0.33,3,0,2),7)
local dRH=mkF(dRight,BG2,UDim2.new(1,0,0,28),UDim2.new(0,0,0,0),7); mkF(dRH,BG2,UDim2.new(1,0,0.5,0),UDim2.new(0,0,0.5,0))
local dName=mkL(dRH,"No script",UDim2.new(1,-180,1,0),UDim2.new(0,6,0,0),CYAN,Enum.Font.GothamBold,11)
local dCopy=mkB(dRH,"Copy",Color3.fromRGB(12,55,55),UDim2.new(0,45,0,22),UDim2.new(1,-160,0,3))
local dSrch=mkTB(dRH,"search (Enter)",UDim2.new(0,105,0,22),UDim2.new(1,-108,0,3))
local dRems=mkB(dRight,"Scan Remote Calls",Color3.fromRGB(68,44,12),UDim2.new(1,-8,0,22),UDim2.new(0,4,0,32))
local dSF=mkSF(dRight,UDim2.new(1,-6,1,-62),UDim2.new(0,3,0,60))
local dTxt=Instance.new("TextLabel",dSF); dTxt.Size=UDim2.new(1,-4,0,9999); dTxt.Position=UDim2.new(0,2,0,2); dTxt.BackgroundTransparency=1; dTxt.TextColor3=Color3.fromRGB(180,225,175); dTxt.Font=Enum.Font.Code; dTxt.TextSize=11; dTxt.TextXAlignment=Enum.TextXAlignment.Left; dTxt.TextYAlignment=Enum.TextYAlignment.Top; dTxt.TextWrapped=true; dTxt.RichText=false; dTxt.Text="<- Click a script"
local function showSrc(src) decompiledSource=src; local out={}; local n=0; for line in (src.."\n"):gmatch("([^\n]*)\n") do n=n+1; out[#out+1]=string.format("%4d | %s",n,line) end; local h=n*13+8; pcall(function() dTxt.Size=UDim2.new(1,-4,0,h); dTxt.Text=table.concat(out,"\n"); dSF.CanvasSize=UDim2.new(0,0,0,h+4); dSF.CanvasPosition=Vector2.new(0,0) end) end
local function decompObj(obj) pcall(function() dName.Text=obj.Name; dTxt.Text="Decompiling..." end); task.spawn(function() local ok,r=pcall(decompile,obj); if ok and type(r)=="string" and #r>10 then showSrc(r); setSt("OK: "..obj.Name) else local ok2,r2=pcall(getscriptbytecode,obj); if ok2 and type(r2)=="string" and #r2>0 then showSrc("-- bytecode\n"..r2); setSt("Bytecode") else pcall(function() dTxt.Text="Failed: "..tostring(r) end); setSt("Failed") end end end) end
local function buildList(flt) for _,c in ipairs(dList:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end; local n=0; for _,s in ipairs(scriptCache) do if flt=="" or s.nm:lower():find(flt:lower(),1,true) then local it=Instance.new("TextButton",dList); it.Size=UDim2.new(1,-4,0,20); it.Text=s.nm; it.BackgroundColor3=BG3; it.BorderSizePixel=0; it.RichText=false; it.TextColor3=s.ref:IsA("LocalScript") and CYAN or (s.ref:IsA("ModuleScript") and PURP or TXT1); it.Font=Enum.Font.Gotham; it.TextSize=10; it.TextXAlignment=Enum.TextXAlignment.Left; Instance.new("UICorner",it).CornerRadius=UDim.new(0,4); local pd=Instance.new("UIPadding",it); pd.PaddingLeft=UDim.new(0,5); local ref=s.ref; it.MouseButton1Click:Connect(function() for _,c2 in ipairs(dList:GetChildren()) do if c2:IsA("TextButton") then pcall(function() c2.BackgroundColor3=BG3 end) end end; pcall(function() it.BackgroundColor3=Color3.fromRGB(22,44,72) end); decompObj(ref) end); n=n+1 end end; pcall(function() dList.CanvasSize=UDim2.new(0,0,0,n*22+4) end) end
dScanB.MouseButton1Click:Connect(function() scriptCache={}; local function f(o) for _,c in ipairs(o:GetChildren()) do if c:IsA("LocalScript") or c:IsA("ModuleScript") or c:IsA("Script") then scriptCache[#scriptCache+1]={nm=c.Name,ref=c} end; pcall(function() f(c) end) end end; pcall(function() f(game) end); buildList(""); setSt("Scripts: "..#scriptCache) end)
dFilt:GetPropertyChangedSignal("Text"):Connect(function() pcall(function() buildList(dFilt.Text) end) end)
dCopy.MouseButton1Click:Connect(function() if decompiledSource~="" then pcall(setclipboard,decompiledSource); setSt("Copied") end end)
dSrch.FocusLost:Connect(function(enter) if not enter or decompiledSource=="" or dSrch.Text=="" then return end; local kw=dSrch.Text; local out={}; local n=0; local ln=0; for line in (decompiledSource.."\n"):gmatch("([^\n]*)\n") do ln=ln+1; if line:lower():find(kw:lower(),1,true) then out[#out+1]=string.format("%4d | %s",ln,line); n=n+1 end end; local h=math.max(n,1)*13+8; pcall(function() dTxt.Size=UDim2.new(1,-4,0,h); dTxt.Text=n>0 and table.concat(out,"\n") or "No: "..kw; dSF.CanvasSize=UDim2.new(0,0,0,h+4) end); if n>0 then setSt(n.." matches") end end)
dRems.MouseButton1Click:Connect(function() if decompiledSource=="" then setSt("Decompile first"); return end; local out={}; local n=0; local ln=0; for line in (decompiledSource.."\n"):gmatch("([^\n]*)\n") do ln=ln+1; if line:find("FireServer") or line:find("InvokeServer") or line:find("FireClient") then out[#out+1]=string.format("%4d | %s",ln,line:match("^%s*(.-)%s*$")); n=n+1 end end; local h=math.max(n,1)*13+8; pcall(function() dTxt.Size=UDim2.new(1,-4,0,h); dTxt.Text=n>0 and table.concat(out,"\n") or "No remote calls"; dSF.CanvasSize=UDim2.new(0,0,0,h+4) end); setSt("Remote calls: "..n) end)

-- ================================================================
-- TAB 5: PLAYERS
-- ================================================================
local plP=mkTab("Players"); local plLog=mkLog(plP,UDim2.new(1,-8,1,-38),UDim2.new(0,4,0,34))
local plRow=mkRow(plP,4,26)
local plAll=plRow("All",Color3.fromRGB(18,50,105)); local plSelf=plRow("Self",Color3.fromRGB(18,66,40))
local plLead=plRow("Leaderstats",Color3.fromRGB(62,52,10)); local plAttr=plRow("Attributes",Color3.fromRGB(42,22,82))
local plCp=plRow("Copy",Color3.fromRGB(12,55,55)); local plCl=plRow("Clear",Color3.fromRGB(50,10,10))
local function scanPl(p,full) plLog.add("[PLR] "..p.Name.." id:"..p.UserId); pcall(function() for k,v in pairs(p:GetAttributes()) do plLog.add("  "..k.."="..tostring(v)) end end); local ls=p:FindFirstChild("leaderstats"); if ls then for _,v in ipairs(ls:GetChildren()) do plLog.add("  "..v.Name.."="..tostring(v.Value)) end end; if full then pcall(function() for _,c in ipairs(p:GetChildren()) do if c.Name~="leaderstats" then plLog.add("  ["..c.ClassName.."] "..c.Name) end end end) end end
plAll.MouseButton1Click:Connect(function() plLog.clear(); plLog.header("All"); for _,p in ipairs(Players:GetPlayers()) do scanPl(p,false) end; plLog.flush() end)
plSelf.MouseButton1Click:Connect(function() plLog.clear(); plLog.header("Self"); scanPl(LP,true); plLog.flush() end)
plLead.MouseButton1Click:Connect(function() plLog.clear(); plLog.header("Leaderstats"); for _,p in ipairs(Players:GetPlayers()) do local ls=p:FindFirstChild("leaderstats"); if ls then plLog.add(p.Name); for _,v in ipairs(ls:GetChildren()) do plLog.add("  "..v.Name.."="..tostring(v.Value)) end end end; plLog.flush() end)
plAttr.MouseButton1Click:Connect(function() plLog.clear(); plLog.header("Attributes"); for _,p in ipairs(Players:GetPlayers()) do local n=0; for _ in pairs(p:GetAttributes()) do n=n+1 end; if n>0 then plLog.add(p.Name); for k,v in pairs(p:GetAttributes()) do plLog.add("  "..k.."="..tostring(v)) end end end; plLog.flush() end)
plCp.MouseButton1Click:Connect(function() plLog.copy() end); plCl.MouseButton1Click:Connect(function() plLog.clear() end)

-- ================================================================
-- START
-- ================================================================
tabs["Scan"].BackgroundColor3=TACC["Scan"]; tabs["Scan"].TextColor3=Color3.fromRGB(255,255,255); pages["Scan"].Visible=true; curTab="Scan"; setSt("Ready")
