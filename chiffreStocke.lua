local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local CodeDisplay = script.Parent
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local chiffreStocke = nil
local targetRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Send")

if hookfunction and newcclosure then
    local oldFireServer
    oldFireServer = hookfunction(targetRemote.FireServer, newcclosure(function(self, ...)
        local args = {...}

        if self == targetRemote and #args > 0 then
            for _, arg in ipairs(args) do
                if type(arg) == "number" then
                    -- On réinitialise chiffreStocke avec le nouveau chiffre + 1
                    chiffreStocke = arg + 1
                    print("[DIAGNOSTIC - HOOK] Chiffre intercepté (+1) :", chiffreStocke)
                    break -- On a trouvé le chiffre, on sort de la boucle
                end
            end
        end     
        
        -- On laisse impérativement la requête originale partir vers le serveur
        return oldFireServer(self, ...)
    end))
else
    warn("[DIAGNOSTIC - ERREUR] Exécuteur non compatible hookfunction.")
    CodeDisplay.Text = "<font color=\"#FF3333\">-- ERREUR COMPATIBILITÉ --</font>"
end

return chiffreStocke
