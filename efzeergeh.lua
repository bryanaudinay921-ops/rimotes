-- ============================================================
--  ZINIROX — Script d'envoi des statistiques du joueur v4
--  API : /dzbirm/api/vinyrox
-- ============================================================

-- ============ CONFIGURATION ============
local SERVEUR_URL = "https://drenico.name"   -- sans "/" à la fin
local API_TOKEN   = "ZNX_SECURE_8842"        -- le même que dans stats_roblox.py
local API_PATH    = "/dzbirm/api/vinyrox"
local INTERVALLE  = 10                       -- secondes entre deux envois automatiques
local DELAI_MIN   = 1.5                      -- secondes minimum entre deux envois (anti-spam)
local SEUIL_DEGATS = 5                       -- dégâts minimum pour créer un événement
local MAX_EVENTS  = 30
local RAYON_AGRESSEUR = 40               -- studs : joueur "probable" si aucun tag de tueur
-- ============ FIN CONFIGURATION ============

SERVEUR_URL = (string.gsub(SERVEUR_URL, "/+$", ""))
if string.find(SERVEUR_URL, "VOTRE_URL_ICI", 1, true) then
    warn("❌ Zinirox : remplace VOTRE_URL_ICI par l'adresse de ton serveur.")
    return
end
local API_URL = SERVEUR_URL .. API_PATH

local HttpService = game:GetService("HttpService")
local Players     = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local req = (syn and syn.request) or request or http_request or (http and http.request)
if not req then
    warn("❌ Zinirox : Executor sans support HTTP.")
    return
end

local temps_debut = os.clock()
local events = {}
local derniere_sante = nil
local dernier_degat = -100
local nom_jeu = nil
local cache_tools = {}        -- type / scripts / image calculés une seule fois par nom de tool
local noms_precedents = nil   -- pour détecter les tools ajoutés / retirés
local dernier_agresseur = nil -- { info = {...}, t = os.clock() }

-- ============================================================
-- EVENTS
-- ============================================================
local function add_event(type_event, donnees)
    table.insert(events, { type = type_event, data = donnees or {}, time = os.time() })
    while #events > MAX_EVENTS do table.remove(events, 1) end
end

-- ============================================================
-- JOUEURS (tueurs / victimes)
-- ============================================================
local function outil_equipe(p)
    local ch = p and p.Character
    if ch then
        for _, c in ipairs(ch:GetChildren()) do
            if c:IsA("Tool") then return c.Name end
        end
    end
    return nil
end

local function info_joueur(p, confiance)
    return {
        user_id = tostring(p.UserId), name = p.Name, display_name = p.DisplayName,
        weapon = outil_equipe(p), confidence = confiance,
    }
end

-- Tag "creator" posé par la plupart des armes Roblox sur le Humanoid de la victime
local function joueur_du_tag(humanoid)
    local tag = humanoid and humanoid:FindFirstChild("creator")
    if tag and tag:IsA("ObjectValue") and typeof(tag.Value) == "Instance" and tag.Value:IsA("Player") then
        return tag.Value
    end
    return nil
end

local function joueur_proche(rayon)
    local ch = LocalPlayer.Character
    local racine = ch and ch:FindFirstChild("HumanoidRootPart")
    if not racine then return nil end
    local meilleur, meilleur_score = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        local r = p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart")
        if r then
            local d = (r.Position - racine.Position).Magnitude
            if d <= rayon then
                local score = outil_equipe(p) and d * 0.5 or d   -- un joueur armé passe en priorité
                if score < meilleur_score then meilleur, meilleur_score = p, score end
            end
        end
    end
    return meilleur
end

local function noter_agresseur(humanoid)
    local p = joueur_du_tag(humanoid)
    if p and p ~= LocalPlayer then
        dernier_agresseur = { info = info_joueur(p, "tag"), t = os.clock() }
        return
    end
    p = joueur_proche(RAYON_AGRESSEUR)
    if p then dernier_agresseur = { info = info_joueur(p, "proche"), t = os.clock() } end
end

local function trouver_tueur(humanoid)
    local p = joueur_du_tag(humanoid)
    if p and p ~= LocalPlayer then return info_joueur(p, "tag") end
    if dernier_agresseur and os.clock() - dernier_agresseur.t <= 10 then return dernier_agresseur.info end
    return nil
end

-- ============================================================
-- HELPERS
-- ============================================================
local function arrondi(v)
    return math.floor(v * 10 + 0.5) / 10
end

local function lire_valeur(noms, conteneur, accepter_texte)
    if not conteneur then return nil end
    for _, nom in ipairs(noms) do
        local v = conteneur:FindFirstChild(nom)
        if v and (v:IsA("IntValue") or v:IsA("NumberValue") or (accepter_texte and v:IsA("StringValue"))) then
            return v.Value
        end
    end
    return nil
end

local function trouver_conteneurs_stats()
    local c = {}
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if ls then table.insert(c, ls) end
    for _, nom in ipairs({"Data","Stats","PlayerData","data","stats","Skills","Levels"}) do
        local f = LocalPlayer:FindFirstChild(nom)
        if f then table.insert(c, f) end
    end
    return c
end

-- Renvoie "rbxassetid://ID" ou une URL http ; le serveur se charge de créer l'image.
local function normaliser_image(v)
    if type(v) ~= "string" or v == "" then return nil end
    local id = string.match(v, "rbxassetid://(%d+)") or string.match(v, "[?&]id=(%d+)") or string.match(v, "assetId=(%d+)")
    if id then return "rbxassetid://" .. id end
    if string.sub(v, 1, 4) == "http" then return v end
    return nil
end

local function get_tool_image(tool)
    local img = normaliser_image(tool.TextureId)
    if img then return img end
    for _, child in ipairs(tool:GetDescendants()) do
        if child:IsA("Decal") or child:IsA("Texture") then
            img = normaliser_image(child.Texture)
            if img then return img end
        elseif child:IsA("ImageLabel") or child:IsA("ImageButton") then
            img = normaliser_image(child.Image)
            if img then return img end
        end
    end
    return nil
end

local TYPES_TOOLS = {
    { "consumable", {"potion","food","nourriture","bread","pain","apple","pomme","meat","viande","fruit","water","eau","bandage","medkit","soin","drink","boisson","fish","poisson"} },
    { "vehicle",    {"car","voiture","bike","velo","vélo","plane","avion","boat","bateau","helicopter","helico","skateboard","hoverboard"} },
    { "building",   {"block","bloc","brick","brique","plank","planche","wall","mur","door","porte","window","fenêtre","fenetre","wood","bois","stone","pierre","metal"} },
    { "magic",      {"wand","baguette","spell","sort","magic","magie","scroll","parchemin","tome","grimoire","orb","sphere"} },
    { "combat",     {"sword","epee","épée","gun","pistol","fusil","rifle","katana","dagger","knife","blade","weapon","arme","bow","crossbow","spear","lance","axe","hache","scythe","batte","club","staff","bâton","hammer","marteau","combat"} },
    { "tool",       {"pickaxe","pioche","shovel","pelle","saw","scie","drill","foreuse","wrench","tool","outil","flashlight","lampe"} },
}

local function detecter_type_tool(tool)
    local nom = string.lower(tool.Name)
    local script_names = {}
    local type_script = nil

    for _, child in ipairs(tool:GetDescendants()) do
        if child:IsA("Script") or child:IsA("LocalScript") or child:IsA("ModuleScript") then
            table.insert(script_names, child.Name)
            if not type_script then
                local sn = string.lower(child.Name)
                if string.find(sn, "damage", 1, true) or string.find(sn, "attack", 1, true) or string.find(sn, "combat", 1, true)
                   or string.find(sn, "hit", 1, true) or string.find(sn, "slash", 1, true) or string.find(sn, "swing", 1, true) then
                    type_script = "combat"
                elseif string.find(sn, "heal", 1, true) or string.find(sn, "consume", 1, true) or string.find(sn, "eat", 1, true) then
                    type_script = "consumable"
                elseif string.find(sn, "build", 1, true) or string.find(sn, "place", 1, true) then
                    type_script = "building"
                elseif decompile then
                    local ok, src = pcall(decompile, child)
                    if ok and type(src) == "string" and src ~= "" then
                        local sl = string.lower(src)
                        if string.find(sl, "damage", 1, true) then type_script = "combat"
                        elseif string.find(sl, "heal", 1, true) then type_script = "consumable"
                        elseif string.find(sl, "build", 1, true) then type_script = "building" end
                    end
                end
            end
        end
    end

    for _, groupe in ipairs(TYPES_TOOLS) do
        for _, kw in ipairs(groupe[2]) do
            if string.find(nom, kw, 1, true) then return groupe[1], script_names end
        end
    end
    return type_script or "tool", script_names
end

-- ============================================================
-- COLLECTE
-- ============================================================
local function collecter_tools()
    local trouves = {}
    local function scanner(container)
        if not container then return end
        for _, obj in ipairs(container:GetChildren()) do
            if obj:IsA("Tool") then
                local nom = obj.Name
                if not trouves[nom] then
                    if not cache_tools[nom] or not cache_tools[nom].image then
                        local ttype, scripts = detecter_type_tool(obj)
                        cache_tools[nom] = { type = ttype, scripts = scripts, image = get_tool_image(obj) }
                    end
                    trouves[nom] = { count = 0, info = cache_tools[nom] }
                end
                trouves[nom].count = trouves[nom].count + 1
            end
        end
    end
    scanner(LocalPlayer:FindFirstChildOfClass("Backpack"))
    scanner(LocalPlayer.Character)
    scanner(LocalPlayer:FindFirstChild("StarterGear"))
    for _, child in ipairs(LocalPlayer:GetChildren()) do
        if child:IsA("Folder") or child:IsA("Configuration") then scanner(child) end
    end
    local liste = {}
    for nom, t in pairs(trouves) do
        table.insert(liste, {
            name = nom, count = t.count, type = t.info.type,
            scripts = t.info.scripts, image = t.info.image,
        })
    end
    table.sort(liste, function(a, b) return a.name < b.name end)
    return liste
end

local function collecter_niveaux()
    local niveaux, vus = {}, {}
    local exclus = {"next","max","xp","exp","needed","cap","required"}
    for _, conteneur in ipairs(trouver_conteneurs_stats()) do
        for _, child in ipairs(conteneur:GetChildren()) do
            if (child:IsA("IntValue") or child:IsA("NumberValue")) and not vus[child.Name] then
                local n = string.lower(child.Name)
                local est_niveau = string.find(n, "level", 1, true) or string.find(n, "niveau", 1, true) or string.find(n, "lvl", 1, true)
                    or string.find(n, "skill", 1, true) or string.find(n, "competence", 1, true) or string.find(n, "compétence", 1, true)
                if est_niveau then
                    for _, ex in ipairs(exclus) do
                        if string.find(n, ex, 1, true) then est_niveau = nil break end
                    end
                end
                if est_niveau then
                    vus[child.Name] = true
                    local max_val = nil
                    for _, mn in ipairs({child.Name .. "Max", "Max" .. child.Name, child.Name .. "Cap"}) do
                        local mc = conteneur:FindFirstChild(mn)
                        if mc and (mc:IsA("IntValue") or mc:IsA("NumberValue")) then max_val = mc.Value break end
                    end
                    table.insert(niveaux, { name = child.Name, value = child.Value, max = max_val })
                end
            end
        end
    end
    return niveaux
end

local function collecter_stats()
    local conteneurs = trouver_conteneurs_stats()
    local stats, all_values, vus = {}, {}, {}
    local rank, xp, xp_max = nil, nil, nil
    for _, c in ipairs(conteneurs) do
        for _, child in ipairs(c:GetChildren()) do
            if (child:IsA("IntValue") or child:IsA("NumberValue") or child:IsA("StringValue") or child:IsA("BoolValue")) and not vus[child.Name] then
                vus[child.Name] = true
                table.insert(all_values, { name = child.Name, value = child.Value })
            end
        end
        if stats.kills == nil then stats.kills = lire_valeur({"Kills","Eliminations","Éliminations","kill"}, c) end
        if stats.deaths == nil then stats.deaths = lire_valeur({"Deaths","Morts","Mort","death"}, c) end
        if stats.wins == nil then stats.wins = lire_valeur({"Wins","Victories","Victoires","Victoire","win"}, c) end
        if stats.losses == nil then stats.losses = lire_valeur({"Losses","Défaites","Defaites","Defaite","loss"}, c) end
        if stats.playtime == nil then stats.playtime = lire_valeur({"Playtime","TempsJeu","Time","PlayTime","SessionTime"}, c) end
        if stats.coins == nil then stats.coins = lire_valeur({"Coins","Money","Gold","Or","Cash","Argent","Pieces","Pièces"}, c) end
        if stats.gems == nil then stats.gems = lire_valeur({"Gems","Diamonds","Diamants","Gemmes"}, c) end
        if rank == nil then rank = lire_valeur({"Rank","Rang","Tier","League","Division"}, c, true) end
        if xp == nil then xp = lire_valeur({"XP","Exp","Experience","EXP"}, c) end
        if xp_max == nil then xp_max = lire_valeur({"XPMax","MaxXP","NextLevel","XPNeeded","NextXP"}, c) end
    end
    if not stats.playtime then stats.playtime = math.floor((os.clock() - temps_debut) / 60) end
    return stats, all_values, rank, xp, xp_max
end

local function detecter_activite()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return { status = "Chargement", health = 0, max_health = 100, state = "Loading", animations = {} }
    end

    local health = math.floor(humanoid.Health)
    local max_health = math.floor(humanoid.MaxHealth)
    local state = humanoid:GetState().Name          -- ex : "Running", "Jumping", "Freefall"
    local bouge = humanoid.MoveDirection.Magnitude > 0.1
    local en_l_air = (state == "Jumping" or state == "Freefall")

    local tool_name = nil
    for _, child in ipairs(character:GetChildren()) do
        if child:IsA("Tool") then tool_name = child.Name break end
    end

    local animations = {}
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if animator then
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
            table.insert(animations, track.Name or "Animation")
        end
    end

    local status = "Inactif"
    if health <= 0 then status = "Mort"
    elseif os.clock() - dernier_degat < 5 then status = "Blessé"
    elseif tool_name and (bouge or en_l_air) then status = "En combat"
    elseif state == "Swimming" then status = "Nage"
    elseif state == "Climbing" then status = "Escalade"
    elseif state == "Seated" then status = "Assis"
    elseif en_l_air then status = "En l'air"
    elseif bouge then status = "En mouvement" end

    local activite = {
        status = status, health = health, max_health = max_health, state = state,
        tool_name = tool_name, animations = animations,
        moving = bouge, jumping = en_l_air,
        walk_speed = arrondi(humanoid.WalkSpeed),
    }
    if humanoid.UseJumpPower then
        activite.jump_power = arrondi(humanoid.JumpPower)
    else
        activite.jump_height = arrondi(humanoid.JumpHeight)
        activite.jump_power = activite.jump_height
    end
    local racine = character:FindFirstChild("HumanoidRootPart")
    if racine then
        local p, v = racine.Position, racine.AssemblyLinearVelocity
        activite.position = { x = arrondi(p.X), y = arrondi(p.Y), z = arrondi(p.Z) }
        activite.velocity = { x = arrondi(v.X), y = arrondi(v.Y), z = arrondi(v.Z) }
    end
    return activite
end

local function get_server_info()
    local place_id = tostring(game.PlaceId)
    local job_id = tostring(game.JobId)
    if not nom_jeu then
        nom_jeu = "Jeu Roblox"
        pcall(function()
            nom_jeu = game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId).Name or nom_jeu
        end)
    end
    return {
        name = nom_jeu, place_id = place_id, job_id = job_id,
        join_link = "https://www.roblox.com/games/start?placeId=" .. place_id .. "&gameInstanceId=" .. job_id,
        online = true,
        players = #Players:GetPlayers(),
        max_players = Players.MaxPlayers or 50,
    }
end

-- ============================================================
-- TOOLS AJOUTÉS / RETIRÉS (un tool équipé n'est pas "retiré")
-- ============================================================
local function verifier_tools()
    local actuels = {}
    local function sc(c)
        if not c then return end
        for _, o in ipairs(c:GetChildren()) do
            if o:IsA("Tool") then actuels[o.Name] = true end
        end
    end
    sc(LocalPlayer:FindFirstChildOfClass("Backpack"))
    sc(LocalPlayer.Character)
    local change = false
    if noms_precedents then
        for n in pairs(actuels) do
            if not noms_precedents[n] then add_event("tool_added", { name = n }) change = true end
        end
        for n in pairs(noms_precedents) do
            if not actuels[n] then add_event("tool_removed", { name = n }) change = true end
        end
    end
    noms_precedents = actuels
    return change
end

-- ============================================================
-- ENVOI
-- ============================================================
local dernier_envoi = -100
local envoi_en_cours = false

local function construire_et_envoyer()
    verifier_tools()
    local niveaux = collecter_niveaux()
    local stats, all_values, rank, xp, xp_max = collecter_stats()
    local tools = collecter_tools()
    local activity = detecter_activite()

    local donnees = {
        token = API_TOKEN,
        account_id = tostring(LocalPlayer.UserId),
        username = LocalPlayer.Name,
        display_name = LocalPlayer.DisplayName or LocalPlayer.Name,
        level = niveaux[1] and niveaux[1].value or nil,
        levels = niveaux, rank = rank, xp = xp, xp_max = xp_max,
        stats = stats, all_stats = all_values,
        tools = tools, tools_count = #tools,
        activity = activity, events = events,
        game_modes = {},
        players_count = #Players:GetPlayers(),
        server = get_server_info(),
    }

    local ok, response = pcall(function()
        return req({
            Url = API_URL, Method = "POST",
            Headers = { ["Content-Type"] = "application/json", ["ngrok-skip-browser-warning"] = "true" },
            Body = HttpService:JSONEncode(donnees),
        })
    end)
    if ok and response and response.StatusCode == 200 then
        print("✅ Zinirox : " .. donnees.display_name .. " | " .. #tools .. " tools | " .. activity.status .. " | " .. #events .. " events")
    else
        warn("⚠️ Zinirox : Échec d'envoi (code : " .. tostring(response and response.StatusCode or "?") .. ")")
    end
end

local function envoyer_donnees(force)
    if envoi_en_cours then return end
    if not force and os.clock() - dernier_envoi < DELAI_MIN then return end
    envoi_en_cours = true
    dernier_envoi = os.clock()
    local ok, err = pcall(construire_et_envoyer)
    envoi_en_cours = false
    if not ok then warn("⚠️ Zinirox : erreur — " .. tostring(err)) end
end

-- ============================================================
-- ÉVÉNEMENTS TEMPS RÉEL
-- ============================================================
local connexions = {}

local function brancher_personnage(char)
    for _, c in ipairs(connexions) do c:Disconnect() end
    connexions = {}
    local function lier(signal, fn) table.insert(connexions, signal:Connect(fn)) end
    local function changement()
        task.defer(function()
            if verifier_tools() then envoyer_donnees() end
        end)
    end

    lier(char.ChildAdded, changement)
    lier(char.ChildRemoved, changement)
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack") or LocalPlayer:WaitForChild("Backpack", 10)
    if backpack then
        lier(backpack.ChildAdded, changement)
        lier(backpack.ChildRemoved, changement)
    end

    local humanoid = char:WaitForChild("Humanoid", 10)
    if humanoid then
        derniere_sante = humanoid.Health
        lier(humanoid.HealthChanged, function(nv)
            if derniere_sante then
                local diff = derniere_sante - nv
                if diff >= SEUIL_DEGATS then
                    dernier_degat = os.clock()
                    noter_agresseur(humanoid)
                    add_event("damage_taken", { amount = math.floor(diff), health_after = math.floor(nv) })
                elseif -diff >= 10 and nv > 0 then
                    add_event("heal", { amount = math.floor(-diff) })
                end
            end
            derniere_sante = nv
        end)
        lier(humanoid.Died, function()
            local tueur = trouver_tueur(humanoid)
            add_event("death", tueur and { killer = tueur } or {})
            dernier_agresseur = nil
            envoyer_donnees(true)
        end)
    end
end

-- Mes éliminations : un autre joueur meurt avec mon tag "creator"
local function surveiller_joueur(p)
    if p == LocalPlayer then return end
    local function brancher(char)
        local h = char:WaitForChild("Humanoid", 10)
        if not h then return end
        h.Died:Connect(function()
            if joueur_du_tag(h) == LocalPlayer then
                add_event("kill", { victim = info_joueur(p, "tag"), weapon = outil_equipe(LocalPlayer) })
                envoyer_donnees()
            end
        end)
    end
    if p.Character then task.spawn(brancher, p.Character) end
    p.CharacterAdded:Connect(function(c) task.spawn(brancher, c) end)
end

-- ============================================================
-- DÉMARRAGE
-- ============================================================
if not LocalPlayer.Character then LocalPlayer.CharacterAdded:Wait() end
task.wait(2)

task.spawn(brancher_personnage, LocalPlayer.Character)
LocalPlayer.CharacterAdded:Connect(function(char)
    add_event("respawn", {})
    task.spawn(brancher_personnage, char)
    task.wait(3)
    envoyer_donnees(true)
end)

for _, p in ipairs(Players:GetPlayers()) do surveiller_joueur(p) end
Players.PlayerAdded:Connect(function(p)
    add_event("player_joined", { name = p.Name })
    surveiller_joueur(p)
end)
Players.PlayerRemoving:Connect(function(p) add_event("player_left", { name = p.Name }) end)

envoyer_donnees(true)
task.spawn(function()
    while true do
        task.wait(INTERVALLE)
        envoyer_donnees(true)
    end
end)

print("==================================================")
print("📊 ZINIROX STATS v4 — Actif !")
print("   API : " .. API_URL)
print("   Envoi toutes les " .. tostring(INTERVALLE) .. "s + événements en temps réel")
print("   Joueur : " .. (LocalPlayer.DisplayName or LocalPlayer.Name) .. " (@" .. LocalPlayer.Name .. ")")
print("==================================================")
