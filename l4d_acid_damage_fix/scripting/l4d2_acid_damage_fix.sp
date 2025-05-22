#include <sourcemod>
#include <sdkhooks>
#include <dhooks>

#define MAXENTITYS 2048
#define GAMEDATA   "l4d2_acid_damage_fix"

float
    AcidTime[MAXPLAYERS + 1][MAXENTITYS + 1],
    g_fRangePercent;
int
    g_iPlugins,
    AcidTypeNum[MAXENTITYS + 1],
    AcidTwice[MAXPLAYERS + 1][MAXENTITYS + 1];
bool
    g_bCloseFix;

ConVar
    g_cvPluginEnable,
    g_cvRangePercent;

public Plugin myinfo =
{
    name        = "l4d_acid_damage_fix",
    author      = "洛琪",
    description = "修复口水伤害频率异常、口水伤害范围异常的问题",
    version     = "1.0.0",
    url         = "https://steamcommunity.com/profiles/76561198812009299/"
};

public void OnPluginStart()
{
    g_cvPluginEnable = CreateConVar("l4d_acid_fix", "1", "插件总开关(0=关闭 1=开启)", FCVAR_NOTIFY);
    g_cvRangePercent = CreateConVar("l4d_acid_range_percent", "75", "口水伤害范围修复比例(范围为0%-100%)，100为默认不修复的范围", FCVAR_NONE, true, 0.0, true, 100.0);
    g_cvPluginEnable.AddChangeHook(ConVarChanged);
    g_cvRangePercent.AddChangeHook(ConVarChanged);

    HookEvent("round_start_pre_entity", Event_RoundStartPre, EventHookMode_PostNoCopy);
    AutoExecConfig(true, "l4d_acid_damage_fix");
    InItVarNum();
    InItGameData();
}

public void OnConfigsExecuted()
{
    GetCvars();
}

void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    GetCvars();
}

void Event_RoundStartPre(Event event, const char[] name, bool dontBroadcast)
{
    InItVarNum();
}

void GetCvars()
{
    g_iPlugins      = g_cvPluginEnable.IntValue;
    g_fRangePercent = g_cvRangePercent.FloatValue / 100.0;
    if(g_fRangePercent > 0.99)
        g_bCloseFix = true;
    else
        g_bCloseFix = false;
}

void InItGameData()
{
    char buffer[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, buffer, sizeof buffer, "gamedata/%s.txt", GAMEDATA);
    if (!FileExists(buffer))
        SetFailState("Missing required file: \"%s\".\n", buffer);

    Handle hGameData = LoadGameConfigFile(GAMEDATA);
    if (hGameData == null) SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);

    DynamicDetour dCInferno_IsTouching = DynamicDetour.FromConf(hGameData, "CInferno::IsTouching");
    if (!dCInferno_IsTouching) SetFailState("Failed to setup detour for CInferno::IsTouching");
    if (!dCInferno_IsTouching.Enable(Hook_Pre, DTR_CInferno_IsTouching_Pre)) SetFailState("Failed to detour for CInferno::IsTouching");

    DynamicDetour dCInferno_Spread = DynamicDetour.FromConf(hGameData, "CInferno::Spread");
    if (!dCInferno_Spread) SetFailState("Failed to setup detour for CInferno::Spread");
    if (!dCInferno_Spread.Enable(Hook_Pre, DTR_CInferno_Spread_Pre)) SetFailState("Failed to detour for CInferno::Spread");

    DynamicDetour dCInsectSwarm_CanHarm = DynamicDetour.FromConf(hGameData, "CInsectSwarm::CanHarm");
    if (!dCInsectSwarm_CanHarm) SetFailState("Failed to setup detour for CInsectSwarm::CanHarm");
    if (!dCInsectSwarm_CanHarm.Enable(Hook_Pre, DTR_CInsectSwarm_CanHarm_Pre)) SetFailState("Failed to detour for CInsectSwarm::CanHarm");

    delete hGameData;
}

MRESReturn DTR_CInferno_IsTouching_Pre(int pThis, DHookReturn hReturn, DHookParam hParams)
{
    if (g_iPlugins == 0 || g_bCloseFix) return MRES_Ignored;

    if (pThis > 0 && pThis < 2048)
    {
        char szClass[32];
        GetEdictClassname(pThis, szClass, sizeof(szClass));
        if (strcmp("insect_swarm", szClass, false) == 0)
        {
            hParams.Set(2, 60.0 * g_fRangePercent);
            return MRES_ChangedHandled;
        }
    }
    return MRES_Ignored;
}

MRESReturn DTR_CInferno_Spread_Pre(int pThis, DHookReturn hReturn, DHookParam hParams)
{
    if (pThis > 0 && pThis < 2048)
    {
        char szClass[32];
        GetEdictClassname(pThis, szClass, sizeof(szClass));
        if (strcmp("insect_swarm", szClass, false) == 0)
        {
            int i              = AcidTypeNum[pThis];
            AcidTypeNum[pThis] = i + 1;
        }
    }
    return MRES_Ignored;
}

MRESReturn DTR_CInsectSwarm_CanHarm_Pre(int pThis, DHookReturn hReturn, DHookParam hParams)
{
    if (g_iPlugins == 0 || g_bCloseFix) return MRES_Ignored;

    if (pThis > 0 && pThis < 2048 && AcidTypeNum[pThis] < 5)
    {
        int entity = DHookGetParam(hParams, 1);
        if (entity >= 1 && entity <= MaxClients && GetClientTeam(entity) == 2)
        {
            float pos[3], vec[3];
            GetClientAbsOrigin(entity, pos);
            GetEntPropVector(pThis, Prop_Send, "m_vecOrigin", vec);
            pos[2] = 0.0, vec[2] = 0.0;
            float dist = GetVectorDistance(pos, vec, true);
            if (dist > 4800.0 * g_fRangePercent)
            {
                hReturn.Value = 0;
                return MRES_Supercede;
            }
        }
    }
    return MRES_Ignored;
}

public void OnEntityDestroyed(int entity)
{
    if(entity > 0 && entity < 2048)
    {
        AcidTypeNum[entity] = 0;
    }  
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

Action OnTakeDamage(int entity, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (g_iPlugins == 0) return Plugin_Continue;

    if (damagetype == 263168 || damagetype == 265216)
    {
        if (inflictor >= 0 && inflictor < 2048 && entity >= 1 && entity <= MaxClients && GetClientTeam(entity) == 2)
        {
            if (AcidTwice[entity][inflictor] < 4)
            {
                int j                        = AcidTwice[entity][inflictor];
                AcidTwice[entity][inflictor] = j + 1;
                return Plugin_Continue;
            }
            else
            {
                if (AcidTime[entity][inflictor] + 1.1 < GetGameTime())
                {
                    AcidTime[entity][inflictor]  = GetGameTime();
                    AcidTwice[entity][inflictor] = 0;
                    return Plugin_Continue;
                }
                else
                {
                    damagetype = 0;
                    damage     = 0.0;
                    return Plugin_Changed;
                }
            }
        }
    }
    return Plugin_Continue;
}

void InItVarNum()
{
    for (int k = 0; k < MAXENTITYS + 1; k++)
    {
        for (int j = 0; j < MAXPLAYERS + 1; j++)
        {
            AcidTime[j][k]  = 0.0;
            AcidTwice[j][k] = 0;
        }
        AcidTypeNum[k] = 0;
    }
    g_bCloseFix = false;
}
