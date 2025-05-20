#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>

#define GAMEDATA "l4d_restart_round_fix"

public Plugin myinfo =
{
    name        = "l4d_restart_tank_fix",
    author      = "洛琪",
    description = "修复当回合重启之后,导演tank容易过早刷出的bug,以及尸潮过早刷新的bug",
    version     = "1.0.0",
    url         = "https://steamcommunity.com/profiles/76561198812009299/"
};

ConVar
    g_cvPluginEnable,
    g_cvMobMaxEasy,
    g_cvMobMaxNormal,
    g_cvMobMaxHard,
    g_cvMobMaxExpert,
    g_cvMobMixEasy,
    g_cvMobMixNormal,
    g_cvMobMixHard,
    g_cvdifficulty,
    g_cvMobMixExpert;

bool
    g_bAllowSpawn = false;

int
    g_iMobSpawnInterval[8],
    g_iChangeNum;

Handle
    g_hTankTimer,
    g_hMobTimer;

Address
    g_pDirector;

public void OnPluginStart()
{
    g_cvPluginEnable = CreateConVar("l4d_restart_round", "1", "插件总开关(0=关闭 1=开启)", FCVAR_NOTIFY);

    g_cvMobMaxEasy   = FindConVar("z_mob_spawn_max_interval_easy");
    g_cvMobMaxNormal = FindConVar("z_mob_spawn_max_interval_normal");
    g_cvMobMaxHard   = FindConVar("z_mob_spawn_max_interval_hard");
    g_cvMobMaxExpert = FindConVar("z_mob_spawn_max_interval_expert");
    g_cvMobMixEasy   = FindConVar("z_mob_spawn_min_interval_easy");
    g_cvMobMixNormal = FindConVar("z_mob_spawn_min_interval_normal");
    g_cvMobMixHard   = FindConVar("z_mob_spawn_min_interval_hard");
    g_cvMobMixExpert = FindConVar("z_mob_spawn_min_interval_expert");
    g_cvdifficulty   = FindConVar("z_difficulty");

    HookEvent("round_start_pre_entity", Event_RoundStartPre, EventHookMode_PostNoCopy);
    HookEvent("player_left_safe_area", Event_LeftSafeArea, EventHookMode_PostNoCopy);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("map_transition", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("mission_lost", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("finale_vehicle_leaving", Event_RoundEnd, EventHookMode_PostNoCopy);

    AutoExecConfig(true, "l4d_restart_round_fix");
    InItGameData();
}

void InItGameData()
{
    char buffer[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, buffer, sizeof buffer, "gamedata/%s.txt", GAMEDATA);
    if (!FileExists(buffer))
        SetFailState("Missing required file: \"%s\".\n", buffer);

    Handle hGameData = LoadGameConfigFile(GAMEDATA);
    if (hGameData == null) SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);

    g_pDirector = GameConfGetAddress(hGameData, "CDirector");
    if (!g_pDirector) SetFailState("Failed to find address: \"CDirector\"");

    DynamicDetour dOnThreatEncountered = DynamicDetour.FromConf(hGameData, "GetThreatType");
    if (!dOnThreatEncountered) SetFailState("Failed to setup detour for CDirector::GetThreatType");
    if (!dOnThreatEncountered.Enable(Hook_Post, Detour_Director_GetThreatType_Post)) SetFailState("Failed to detour for CDirector::GetThreatType");
    delete hGameData;
}

MRESReturn Detour_Director_GetThreatType_Post(DHookReturn hReturn)
{
    if (g_cvPluginEnable.IntValue == 0) return MRES_Ignored;

    if (!g_bAllowSpawn)
    {
        if (hReturn.Value == 8)
        {
            hReturn.Value = 7;
            g_iChangeNum++;
            return MRES_Override;
        }
    }
    else
    {
        if (hReturn.Value == 7 && g_iChangeNum > 0)
        {
            hReturn.Value = 8;
            g_iChangeNum--;
            return MRES_Override;
        }
    }
    return MRES_Ignored;
}

void Event_RoundStartPre(Event event, const char[] name, bool dontBroadcast)
{
    g_bAllowSpawn = false;
    g_iChangeNum  = 0;
    for (int i = 0; i < 8; i++)
    {
        g_iMobSpawnInterval[i] = 0;
    }
}

void Event_LeftSafeArea(Event event, const char[] name, bool dontBroadcast)
{
    g_hTankTimer = CreateTimer(45.0, Timer_DelayAllowSpawn, _, TIMER_FLAG_NO_MAPCHANGE);
    g_hMobTimer  = CreateTimer(1.0, Timer_CheckMobTimer, _, TIMER_FLAG_NO_MAPCHANGE);
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (g_hTankTimer != null)
    {
        delete g_hTankTimer;
    }
    if (g_hMobTimer != null)
    {
        delete g_hMobTimer;
    }
}

Action Timer_DelayAllowSpawn(Handle timer)
{
    g_bAllowSpawn = true;
    g_hTankTimer  = null;
    return Plugin_Continue;
}

Action Timer_CheckMobTimer(Handle timer)
{
    SetArrayData();
    int   index    = ReturnDifficutlyInt();
    float duration = view_as<float>(LoadFromAddress(g_pDirector + view_as<Address>(660 + 4), NumberType_Int32));
    duration       = duration > 0.0 ? duration : 0.0;
    if (duration < g_iMobSpawnInterval[index + 4] || duration > g_iMobSpawnInterval[index])
    {
        float interval = GetRandomFloat(float(g_iMobSpawnInterval[index + 4]), float(g_iMobSpawnInterval[index]));
        int   off      = 660 + view_as<int>(g_pDirector);
        StoreToAddress(view_as<Address>(off + 8), view_as<int>(GetGameTime() + interval), NumberType_Int32, false);
        StoreToAddress(view_as<Address>(off + 4), view_as<int>(interval), NumberType_Int32, false);
    }
    g_hMobTimer = null;
    return Plugin_Continue;
}

int ReturnDifficutlyInt()
{
    int  g_iDiffculty = 0;
    char sDifficulty[32];
    GetConVarString(g_cvdifficulty, sDifficulty, sizeof(sDifficulty));
    if (strcmp("Easy", sDifficulty, false) == 0)
        g_iDiffculty = 0;
    else if (strcmp("Normal", sDifficulty, false) == 0)
        g_iDiffculty = 1;
    else if (strcmp("Hard", sDifficulty, false) == 0)
        g_iDiffculty = 2;
    else if (strcmp("Impossible", sDifficulty, false) == 0)
        g_iDiffculty = 3;
    else
        g_iDiffculty = 1;
    return g_iDiffculty;
}

void SetArrayData()
{
    g_iMobSpawnInterval[0] = g_cvMobMaxEasy.IntValue;
    g_iMobSpawnInterval[1] = g_cvMobMaxNormal.IntValue;
    g_iMobSpawnInterval[2] = g_cvMobMaxHard.IntValue;
    g_iMobSpawnInterval[3] = g_cvMobMaxExpert.IntValue;
    g_iMobSpawnInterval[4] = g_cvMobMixEasy.IntValue;
    g_iMobSpawnInterval[5] = g_cvMobMixNormal.IntValue;
    g_iMobSpawnInterval[6] = g_cvMobMixHard.IntValue;
    g_iMobSpawnInterval[7] = g_cvMobMixExpert.IntValue;
}
