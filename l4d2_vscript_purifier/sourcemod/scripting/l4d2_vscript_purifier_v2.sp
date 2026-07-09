#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>
#include <l4d2_source_keyvalues>

#define GAMEDATA                "l4d2_vscript_purifier_v2"
#define GAMEDATA_VERSION        8
#define VPK_RULE_NONE           0
#define VPK_RULE_WHITELIST      1
#define VPK_RULE_BLACKLIST      2
#define VPK_RULE_KEY_MAX        600
#define ADDONLIST_RESTORE_DELAY 0.5

methodmap GameDataWrapper < GameData
{

public     GameDataWrapper(const char[] file)
    {
        GameData gameData = new GameData(file);
        if (!gameData)
            SetFailState("[GameData] Missing gamedata of file \"%s\".", file);

        return view_as<GameDataWrapper>(gameData);
    }

public     DynamicDetour CreateDetourOrFail(const char[] name,
                                     bool          now      = true,
                                     DHookCallback preHook  = INVALID_FUNCTION,
                                     DHookCallback postHook = INVALID_FUNCTION)
    {
        DynamicDetour setup = DynamicDetour.FromConf(this, name);

        if (!setup)
            SetFailState("[Detour] Missing detour setup section \"%s\".", name);

        if (now)
        {
            if (preHook != INVALID_FUNCTION && !setup.Enable(Hook_Pre, preHook))
                SetFailState("[Detour] Failed to pre-detour of section \"%s\".", name);

            if (postHook != INVALID_FUNCTION && !setup.Enable(Hook_Post, postHook))
                SetFailState("[Detour] Failed to post-detour of section \"%s\".", name);
        }

        return setup;
    }
}

enum AddonMetadataType
{
    Metadata_Mission = 1,
    MetaData_Mode    = 2,
};

enum struct AddonMetadata
{
    char              file[128];
    char              name[128];
    AddonMetadataType type;
    int               unknown;
}

ArrayList
    g_hContentList,
    g_hChangedCvars,
    g_hBlockedMissionVpks,
    g_hAllowedMapVpks,
    g_hLastFilterTargets;

Address
    g_pAddonMetadataVector;

ConVar
    g_hCvarSwitch,
    g_hCvarRestore;

bool
    g_bAllowCall,
    g_bIsLinuxOS,
    g_bMissionReload,
    g_bFoundVpk,
    g_bAddonListFilterArmed,
    g_bAddonListUpdateActive,
    g_bGbkMapLoaded,
    g_bAddonListFilterApplied,
    g_bAddonListRestorePending;

Handle
    g_hAddonListRestoreTimer;

int
    g_iCvarSwitch,
    g_iCvarRestore,
    g_iBlacklistedRuleCount,
    g_iAddonListLoadCallCount,
    g_iGbkUnicodeMap[65536];

StringMap
    g_hVpkRules;

char
    CurrentMapName[128],
    g_sVpkRulesPath[PLATFORM_MAX_PATH];

public Plugin myinfo =
{
    name        = "l4d2_vscript_purifier_v2",
    author      = "洛琪, Forgetest",
    description = "防止地图脚本污染",
    version     = "2.0",
    url         = "https://steamcommunity.com/profiles/76561198812009299/"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    if (GetEngineVersion() != Engine_Left4Dead2 || !IsDedicatedServer())
    {
        strcopy(error, err_max, "Plugin only supports Left 4 Dead 2 And only supports Dedicated Server");
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

public void OnPluginStart()
{
    g_hCvarSwitch = CreateConVar(
        "l4d2_vscript_purifier_v2",
        "1",
        "是否阻止非法脚本造成脚本污染,0不阻止, 1阻止,\\n[注意,地图脚本必须和地图mission文件放在同一个vpk内，才会被识别为地图脚本，否则会识别为脚本类MOD]",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        3.0);

    g_hCvarRestore = CreateConVar(
        "l4d2_vscript_cvarRestore_v2",
        "1",
        "是否在过关时自动还原被脚本修改的cvar值,1是,0否.",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        1.0);

    g_hCvarSwitch.AddChangeHook(OnCvarChanged);
    g_hCvarRestore.AddChangeHook(OnCvarChanged);

    AutoExecConfig(true, "l4d2_vscript_purifier_v2");

    InitGameData();

    BuildPath(Path_SM, g_sVpkRulesPath, sizeof(g_sVpkRulesPath), "data/l4d2_vscript_purifier_v2_vpkrules.txt");

    LoadVpkRulesCache();
    LoadGbkUnicodeMap();

    RegAdminCmd("sm_vpklist", Command_VpkList, ADMFLAG_ROOT, "Open VPK whitelist/blacklist menu.");
    RegAdminCmd("sm_vpkmenu", Command_VpkList, ADMFLAG_ROOT, "Open VPK whitelist/blacklist menu.");

    UpdateCvars();
    ExecConfigsEarly();

    HookEvent("round_start_pre_entity", Event_PreRoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_freeze_end", Event_PostRoundStart, EventHookMode_PostNoCopy);
}

public void OnPluginEnd()
{
    RestoreAddonListFilterNow("plugin end");

    delete g_hVpkRules;
    g_hVpkRules = null;
}

public void OnMapEnd()
{
    RestoreAddonListFilterNow("map end");
}

public void OnServerEnterHibernation()
{
    RestoreAddonListFilterNow("server hibernation");
}

public void OnMapInit(const char[] mapName)
{
    delete g_hContentList;
    delete g_hBlockedMissionVpks;
    delete g_hAllowedMapVpks;

    g_hContentList        = new ArrayList(ByteCountToCells(256));
    g_hBlockedMissionVpks = new ArrayList(ByteCountToCells(256));
    g_hAllowedMapVpks     = new ArrayList(ByteCountToCells(256));

    FormatEx(CurrentMapName, sizeof(CurrentMapName), mapName);

    g_bFoundVpk = false;

    ServerCommand("mission_reload");
    ServerExecute();

    bool isOfficialMap = (g_hBlockedMissionVpks.Length == 0);

    char missionPath[256];
    missionPath[0] = '\0';

    if (!isOfficialMap)
        g_hBlockedMissionVpks.GetString(0, missionPath, sizeof(missionPath));

    AddonMetadata metadata;
    Address       memory = LoadFromAddress(g_pAddonMetadataVector, NumberType_Int32);
    int           size   = LoadFromAddress(g_pAddonMetadataVector + view_as<Address>(12), NumberType_Int32);

    for (int i = 0; i < size; ++i)
    {
        ReadMemoryString(memory + view_as<Address>(i * 4 * sizeof(metadata) + 4 * AddonMetadata::file), metadata.file, sizeof(metadata.file));
        ReadMemoryString(memory + view_as<Address>(i * 4 * sizeof(metadata) + 4 * AddonMetadata::name), metadata.name, sizeof(metadata.name));

        metadata.type    = LoadFromAddress(memory + view_as<Address>(i * 4 * sizeof(metadata) + 4 * AddonMetadata::type), NumberType_Int32);
        metadata.unknown = LoadFromAddress(memory + view_as<Address>(i * 4 * sizeof(metadata) + 4 * AddonMetadata::unknown), NumberType_Int32);

        char vpkName[256];
        GetBaseNameFromPath(metadata.file, vpkName, sizeof(vpkName));

        int len = strlen(vpkName);
        if (len < 4)
            continue;

        char suffix[5];
        strcopy(suffix, sizeof(suffix), vpkName[len - 4]);

        if (!StrEqual(suffix, ".vpk", false))
            continue;

        if (metadata.type == Metadata_Mission)
        {
            if (isOfficialMap)
                continue;

            if (StrContains(missionPath, metadata.name, false) == -1)
                PushStringUnique(g_hBlockedMissionVpks, vpkName);
            else
                PushStringUnique(g_hAllowedMapVpks, vpkName);
        }
        else
        {
            PushStringUnique(g_hContentList, vpkName);
        }
    }

    if (!isOfficialMap && g_hBlockedMissionVpks.Length > 0)
        g_hBlockedMissionVpks.Erase(0);

    g_bAllowCall = true;

    Call_VeryEarly();
}

void Event_PreRoundStart(Event event, const char[] name, bool dontBroadcast)
{
    Call_VeryEarly();
}

void Event_PostRoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bAllowCall = true;
}

void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    UpdateCvars();
}

void UpdateCvars()
{
    g_iCvarSwitch  = g_hCvarSwitch.IntValue;
    g_iCvarRestore = g_hCvarRestore.IntValue;
}

void ExecConfigsEarly()
{
    ServerCommand("exec sourcemod/l4d2_vscript_purifier_v2.cfg");
    ServerExecute();
    UpdateCvars();
}

void Call_VeryEarly()
{
    if (!g_bAllowCall)
        return;

    RestoreConvarDefault();

    delete g_hChangedCvars;
    g_hChangedCvars = new ArrayList(ByteCountToCells(64));

    g_bAllowCall    = false;
}

void RestoreConvarDefault()
{
    if (g_iCvarRestore != 1 || g_hChangedCvars == null)
        return;

    char   buffer[64];
    ConVar tempCvar;

    for (int i = 0; i < g_hChangedCvars.Length; i++)
    {
        tempCvar = null;

        g_hChangedCvars.GetString(i, buffer, sizeof(buffer));
        tempCvar = FindConVar(buffer);

        if (tempCvar != null)
            tempCvar.RestoreDefault(true);
    }
}

MRESReturn DTR_PreVScriptServerRunScriptForAllAddons(DHookReturn hReturn, DHookParam hParams)
{
    ApplyAddonListFilter();
    return MRES_Ignored;
}

MRESReturn DTR_PostVScriptServerRunScriptForAllAddons(DHookReturn hReturn, DHookParam hParams)
{
    ScheduleAddonListRestore();
    return MRES_Ignored;
}

MRESReturn DTR_PreCDirectorChallengeMode_InitScriptsNonVirtual(DHookReturn hReturn)
{
    ApplyAddonListFilter();
    return MRES_Ignored;
}

MRESReturn DTR_PostCDirectorChallengeMode_InitScriptsNonVirtual(DHookReturn hReturn, DHookParam hParams)
{
    ScheduleAddonListRestore();
    return MRES_Ignored;
}

MRESReturn DTR_PreFileSystem_UpdateAddonSearchPaths(DHookReturn hReturn)
{
    g_bAddonListUpdateActive  = true;
    g_iAddonListLoadCallCount = 0;

    return MRES_Ignored;
}

MRESReturn DTR_PostFileSystem_UpdateAddonSearchPaths(DHookReturn hReturn)
{
    g_bAddonListUpdateActive  = false;
    g_iAddonListLoadCallCount = 0;

    if (g_bAddonListRestorePending)
    {
        g_bAddonListRestorePending = false;
        g_bAddonListFilterApplied  = false;
        g_bAddonListFilterArmed    = false;

        delete g_hLastFilterTargets;
        g_hLastFilterTargets = null;
    }

    return MRES_Ignored;
}

MRESReturn DTR_LoadAddonListFile_Post(DHookReturn hReturn, DHookParam hParams)
{
    g_iAddonListLoadCallCount++;

    char file[PLATFORM_MAX_PATH];
    DHookGetParamString(hParams, 1, file, sizeof(file));

    Address ppKv = DHookGetParamAddress(hParams, 2);
    Address pKv  = Address_Null;

    if (ppKv != Address_Null)
        pKv = view_as<Address>(LoadFromAddress(ppKv, NumberType_Int32));

    if (pKv == Address_Null)
        return MRES_Ignored;

    SourceKeyValues kv = view_as<SourceKeyValues>(pKv);

    if (g_bAddonListUpdateActive
        && g_bAddonListFilterArmed
        && !g_bAddonListRestorePending
        && g_iAddonListLoadCallCount == 2)
    {
        ApplyAddonListKeyValuesFilter(kv);
    }

    return MRES_Ignored;
}

MRESReturn DTR_PreParseMissionFromFile(Address pMatchExtL4D, DHookReturn hReturn, DHookParam hParams)
{
    char buffer[256];
    DHookGetParamString(hParams, 1, buffer, sizeof(buffer));

    if (!g_bFoundVpk)
    {
        g_bMissionReload = true;

        if (StrContains(buffer, "missions", false) != -1)
        {
            if (g_hBlockedMissionVpks != null && g_hBlockedMissionVpks.Length != 0)
                g_hBlockedMissionVpks.Erase(0);

            if (g_hBlockedMissionVpks != null)
                g_hBlockedMissionVpks.PushString(buffer);
        }
    }

    return MRES_Ignored;
}

MRESReturn DTR_ParseMissionFromFile_Post(Address pMatchExtL4D, DHookReturn hReturn, DHookParam hParams)
{
    g_bMissionReload = false;
    return MRES_Ignored;
}

MRESReturn DTR_KeyValues_GetString_Post(Address pKeyValue, DHookReturn hReturn, DHookParam hParams)
{
    if (!g_bMissionReload)
        return MRES_Ignored;

    if (!DHookIsNullParam(hParams, 1))
    {
        char key[64];
        DHookGetParamString(hParams, 1, key, sizeof(key));

        char value[256];
        DHookGetReturnString(hReturn, value, sizeof(value));

        if (StrEqual(key, "map", false) && StrEqual(CurrentMapName, value, false))
            g_bFoundVpk = true;
    }

    return MRES_Ignored;
}

MRESReturn DTR_PreCServerGameDLL_GetMatchmakingGameData(DHookReturn hReturn, DHookParam hParams)
{
    RestoreAddonListFilterNow("before matchmaking data");
    return MRES_Ignored;
}

MRESReturn DTR_PreCScriptConvarAccessor_SetValue(DHookReturn hReturn, DHookParam hParams)
{
    char cvarName[64];
    DHookGetParamString(hParams, 1, cvarName, sizeof(cvarName));

    if (g_hChangedCvars == null)
        g_hChangedCvars = new ArrayList(ByteCountToCells(64));

    g_hChangedCvars.PushString(cvarName);

    return MRES_Ignored;
}

bool ApplyAddonListFilter()
{
    if (g_iCvarSwitch <= 0)
        return false;

    if ((g_hBlockedMissionVpks == null || g_hBlockedMissionVpks.Length == 0) && !HasBlacklistedVpkRules())
        return false;

    KillAddonListRestoreTimer();

    if (g_bAddonListFilterApplied && ArrayListStringSetEquals(g_hLastFilterTargets, g_hBlockedMissionVpks))
    {
        return true;
    }

    g_bAddonListFilterArmed    = true;
    g_bAddonListRestorePending = false;

    SaveLastFilterTargets();

    ExecuteUpdateAddonPaths("apply memory filter");

    g_bAddonListFilterApplied = true;

    return true;
}

void ScheduleAddonListRestore()
{
    if (!g_bAddonListFilterApplied)
        return;

    KillAddonListRestoreTimer();

    g_hAddonListRestoreTimer = CreateTimer(
        ADDONLIST_RESTORE_DELAY,
        Timer_RestoreAddonListFilter,
        _,
        TIMER_FLAG_NO_MAPCHANGE);
}

void KillAddonListRestoreTimer()
{
    if (g_hAddonListRestoreTimer != null)
    {
        KillTimer(g_hAddonListRestoreTimer);
        g_hAddonListRestoreTimer = null;
    }
}

Action Timer_RestoreAddonListFilter(Handle timer)
{
    if (timer == g_hAddonListRestoreTimer)
        g_hAddonListRestoreTimer = null;

    RestoreAddonListFilterNow("restore timer");

    return Plugin_Stop;
}

bool RestoreAddonListFilterNow(const char[] reason)
{
    KillAddonListRestoreTimer();

    if (!g_bAddonListFilterApplied && !g_bAddonListFilterArmed)
    {
        return false;
    }

    g_bAddonListFilterArmed    = false;
    g_bAddonListRestorePending = true;

    ExecuteUpdateAddonPaths(reason);

    return true;
}

void ApplyAddonListKeyValuesFilter(SourceKeyValues kv)
{
    if (kv.IsNull())
        return;

    SourceKeyValues cur = kv.GetFirstValue();

    while (cur != view_as<SourceKeyValues>(0) && !cur.IsNull())
    {
        char key[256];
        cur.GetName(key, sizeof(key));

        if (ShouldDisableAddonListKey(key))
        {
            kv.SetInt(key, 0);
        }

        cur = cur.GetNextValue();
    }
}

bool ShouldDisableAddonListKey(const char[] addonKey)
{
    char vpkName[256];
    GetBaseNameFromPath(addonKey, vpkName, sizeof(vpkName));

    int rule = GetVpkRule(vpkName);

    if (rule == VPK_RULE_WHITELIST)
        return false;

    if (rule == VPK_RULE_BLACKLIST)
        return true;

    if (ArrayListHasString(g_hAllowedMapVpks, vpkName, false))
        return false;

    if (ArrayListHasString(g_hBlockedMissionVpks, vpkName, false))
        return true;

    return false;
}

void ExecuteUpdateAddonPaths(const char[] reason)
{
    ServerCommand("update_addon_paths");
    ServerExecute();
    LogMessage("update addon paths reason: %s", reason);
}

public Action Command_VpkList(int client, int args)
{
    if (client <= 0)
        return Plugin_Handled;

    DisplayVpkCategoryMenu(client);
    return Plugin_Handled;
}

void DisplayVpkCategoryMenu(int client)
{
    Menu menu = new Menu(MenuHandler_VpkCategory);
    menu.SetTitle("VPK 黑白名单管理");

    menu.AddItem("mission", "地图 VPK");
    menu.AddItem("content", "普通 VPK");

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_VpkCategory(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char info[32];
        menu.GetItem(item, info, sizeof(info));

        if (StrEqual(info, "mission", false))
            DisplayVpkRuleMenu(client, true);
        else
            DisplayVpkRuleMenu(client, false);
    }
    else if (action == MenuAction_Cancel)
    {
        PrintToChat(client, "\x04[VPK]\x01 修改后下次回合重启/脚本加载时生效。");
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

void DisplayVpkRuleMenu(int client, bool missionVpk)
{
    Menu menu = new Menu(MenuHandler_VpkRule);

    if (missionVpk)
        menu.SetTitle("地图 VPK 黑白名单");
    else
        menu.SetTitle("普通 VPK 黑白名单");

    ArrayList list = new ArrayList(ByteCountToCells(256));
    char      vpkName[256];

    if (missionVpk)
    {
        if (g_hAllowedMapVpks != null)
        {
            for (int i = 0; i < g_hAllowedMapVpks.Length; i++)
            {
                g_hAllowedMapVpks.GetString(i, vpkName, sizeof(vpkName));
                PushStringUnique(list, vpkName);
            }
        }

        if (g_hBlockedMissionVpks != null)
        {
            for (int i = 0; i < g_hBlockedMissionVpks.Length; i++)
            {
                g_hBlockedMissionVpks.GetString(i, vpkName, sizeof(vpkName));
                PushStringUnique(list, vpkName);
            }
        }
    }
    else if (g_hContentList != null)
    {
        for (int i = 0; i < g_hContentList.Length; i++)
        {
            g_hContentList.GetString(i, vpkName, sizeof(vpkName));
            PushStringUnique(list, vpkName);
        }
    }

    if (list.Length == 0)
    {
        menu.AddItem("", "当前没有扫描到 VPK", ITEMDRAW_DISABLED);
    }
    else
    {
        char info[300];
        char display[300];
        char prefix[16];
        char displayName[256];

        for (int i = 0; i < list.Length; i++)
        {
            list.GetString(i, vpkName, sizeof(vpkName));

            if (missionVpk)
                FormatEx(info, sizeof(info), "M|%s", vpkName);
            else
                FormatEx(info, sizeof(info), "C|%s", vpkName);

            int rule = GetVpkRule(vpkName);

            GetVpkRulePrefix(rule, prefix, sizeof(prefix));
            FormatDisplayVpkName(vpkName, displayName, sizeof(displayName));

            FormatEx(display, sizeof(display), "%s %s", prefix, displayName);

            menu.AddItem(info, display);
        }
    }

    delete list;

    menu.ExitBackButton = true;
    menu.ExitButton     = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

int MenuHandler_VpkRule(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_Select)
    {
        char info[300];
        char vpkName[256];

        menu.GetItem(item, info, sizeof(info));

        int separator = FindCharInString(info, '|');
        if (separator == -1 || info[separator + 1] == '\0')
        {
            PrintToChat(client, "\x04[VPK]\x01 菜单数据异常，无法读取 VPK 名称。");
            return 0;
        }

        char category = info[0];
        strcopy(vpkName, sizeof(vpkName), info[separator + 1]);

        int rule = GetVpkRule(vpkName);
        rule++;

        if (rule > VPK_RULE_BLACKLIST)
            rule = VPK_RULE_NONE;

        SetVpkRule(vpkName, rule);

        char ruleName[16];
        char displayName[256];

        GetVpkRuleName(rule, ruleName, sizeof(ruleName));
        FormatDisplayVpkName(vpkName, displayName, sizeof(displayName));

        PrintToChat(client, "\x04[VPK]\x01 %s 已切换为：%s", displayName, ruleName);

        if (category == 'M')
            DisplayVpkRuleMenu(client, true);
        else
            DisplayVpkRuleMenu(client, false);
    }
    else if (action == MenuAction_Cancel)
    {
        if (item == MenuCancel_ExitBack)
            DisplayVpkCategoryMenu(client);
        else
            PrintToChat(client, "\x04[VPK]\x01 修改后下次回合重启/脚本加载时生效。");
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

bool HasBlacklistedVpkRules()
{
    return g_iBlacklistedRuleCount > 0;
}

void GetVpkRulePrefix(int rule, char[] buffer, int maxlen)
{
    switch (rule)
    {
        case VPK_RULE_WHITELIST:
            strcopy(buffer, maxlen, "[白名单]");

        case VPK_RULE_BLACKLIST:
            strcopy(buffer, maxlen, "[黑名单]");

        default:
            strcopy(buffer, maxlen, "[未加入]");
    }
}

void GetVpkRuleName(int rule, char[] buffer, int maxlen)
{
    switch (rule)
    {
        case VPK_RULE_WHITELIST:
            strcopy(buffer, maxlen, "白名单");

        case VPK_RULE_BLACKLIST:
            strcopy(buffer, maxlen, "黑名单");

        default:
            strcopy(buffer, maxlen, "未加入");
    }
}

void LoadVpkRulesCache()
{
    delete g_hVpkRules;
    g_hVpkRules             = new StringMap();

    g_iBlacklistedRuleCount = 0;

    if (!FileExists(g_sVpkRulesPath))
        return;

    KeyValues kv = new KeyValues("VpkRules");

    if (!kv.ImportFromFile(g_sVpkRulesPath))
    {
        delete kv;
        LogError("[VPKRules] failed to load rules file: %s", g_sVpkRulesPath);
        return;
    }

    if (kv.GotoFirstSubKey())
    {
        char sectionName[VPK_RULE_KEY_MAX];
        char ruleKey[VPK_RULE_KEY_MAX];

        do
        {
            kv.GetSectionName(sectionName, sizeof(sectionName));

            if (!IsVpkRuleStorageKey(sectionName))
                continue;

            strcopy(ruleKey, sizeof(ruleKey), sectionName);

            int rule = kv.GetNum("rule", VPK_RULE_NONE);

            if (rule < VPK_RULE_NONE || rule > VPK_RULE_BLACKLIST)
                rule = VPK_RULE_NONE;

            if (rule == VPK_RULE_NONE)
                continue;

            g_hVpkRules.SetValue(ruleKey, rule);

            if (rule == VPK_RULE_BLACKLIST)
                g_iBlacklistedRuleCount++;
        }
        while (kv.GotoNextKey());
    }

    delete kv;
}

bool SaveVpkRulesCache()
{
    KeyValues         kv       = new KeyValues("VpkRules");
    StringMapSnapshot snapshot = g_hVpkRules.Snapshot();

    char              ruleKey[VPK_RULE_KEY_MAX];

    for (int i = 0; i < snapshot.Length; i++)
    {
        snapshot.GetKey(i, ruleKey, sizeof(ruleKey));

        int rule = VPK_RULE_NONE;
        if (!g_hVpkRules.GetValue(ruleKey, rule))
            continue;

        if (rule == VPK_RULE_NONE)
            continue;

        if (!kv.JumpToKey(ruleKey, true))
            continue;

        kv.SetNum("rule", rule);
        kv.GoBack();
    }

    delete snapshot;

    bool result = kv.ExportToFile(g_sVpkRulesPath);

    delete kv;

    if (!result)
        LogError("[VPKRules] failed to save rules file: %s", g_sVpkRulesPath);

    return result;
}

int GetVpkRule(const char[] vpkName)
{
    if (g_hVpkRules == null)
        return VPK_RULE_NONE;

    char ruleKey[VPK_RULE_KEY_MAX];
    BuildVpkRuleStorageKey(vpkName, ruleKey, sizeof(ruleKey));

    int rule = VPK_RULE_NONE;

    if (!g_hVpkRules.GetValue(ruleKey, rule))
        return VPK_RULE_NONE;

    if (rule < VPK_RULE_NONE || rule > VPK_RULE_BLACKLIST)
        return VPK_RULE_NONE;

    return rule;
}

bool SetVpkRule(const char[] vpkName, int rule)
{
    if (g_hVpkRules == null)
        g_hVpkRules = new StringMap();

    char ruleKey[VPK_RULE_KEY_MAX];
    BuildVpkRuleStorageKey(vpkName, ruleKey, sizeof(ruleKey));

    int oldRule = GetVpkRule(vpkName);

    if (oldRule == VPK_RULE_BLACKLIST && g_iBlacklistedRuleCount > 0)
        g_iBlacklistedRuleCount--;

    if (rule < VPK_RULE_NONE || rule > VPK_RULE_BLACKLIST)
        rule = VPK_RULE_NONE;

    if (rule == VPK_RULE_NONE)
    {
        g_hVpkRules.Remove(ruleKey);
    }
    else
    {
        g_hVpkRules.SetValue(ruleKey, rule);

        if (rule == VPK_RULE_BLACKLIST)
            g_iBlacklistedRuleCount++;
    }

    return SaveVpkRulesCache();
}

bool ArrayListHasString(ArrayList list, const char[] value, bool caseSensitive = false)
{
    if (list == null)
        return false;

    char buffer[256];

    for (int i = 0; i < list.Length; i++)
    {
        list.GetString(i, buffer, sizeof(buffer));

        if (StrEqual(buffer, value, caseSensitive))
            return true;
    }

    return false;
}

void PushStringUnique(ArrayList list, const char[] value)
{
    if (list == null)
        return;

    if (!ArrayListHasString(list, value, false))
        list.PushString(value);
}

bool ArrayListStringSetEquals(ArrayList listA, ArrayList listB)
{
    if (listA == null && listB == null)
        return true;

    if (listA == null || listB == null)
        return false;

    if (listA.Length != listB.Length)
        return false;

    char buffer[256];

    for (int i = 0; i < listA.Length; i++)
    {
        listA.GetString(i, buffer, sizeof(buffer));

        if (!ArrayListHasString(listB, buffer, false))
            return false;
    }

    return true;
}

void SaveLastFilterTargets()
{
    delete g_hLastFilterTargets;
    g_hLastFilterTargets = new ArrayList(ByteCountToCells(256));

    if (g_hBlockedMissionVpks == null)
        return;

    char buffer[256];

    for (int i = 0; i < g_hBlockedMissionVpks.Length; i++)
    {
        g_hBlockedMissionVpks.GetString(i, buffer, sizeof(buffer));
        PushStringUnique(g_hLastFilterTargets, buffer);
    }
}

void GetBaseNameFromPath(const char[] path, char[] output, int maxlen)
{
    int slash1 = FindCharInString(path, '/', true);
    int slash2 = FindCharInString(path, '\\', true);
    int slash  = slash1 > slash2 ? slash1 : slash2;

    if (slash == -1)
        strcopy(output, maxlen, path);
    else
        strcopy(output, maxlen, path[slash + 1]);
}

bool IsSpaceChar(char c)
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

int HexDigitValue(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';

    if (c >= 'a' && c <= 'f')
        return 10 + (c - 'a');

    if (c >= 'A' && c <= 'F')
        return 10 + (c - 'A');

    return -1;
}

bool ParseHexInt(const char[] text, int &value)
{
    value = 0;

    int i = 0;
    if (text[0] == '0' && (text[1] == 'x' || text[1] == 'X'))
        i = 2;

    bool found = false;

    for (; text[i] != '\0'; i++)
    {
        int digit = HexDigitValue(text[i]);
        if (digit < 0)
            return false;

        value = (value << 4) | digit;
        found = true;
    }

    return found;
}

bool ReadNextToken(const char[] src, int &pos, char[] token, int maxlen)
{
    token[0] = '\0';

    while (src[pos] != '\0' && IsSpaceChar(src[pos]))
        pos++;

    if (src[pos] == '\0')
        return false;

    int start = pos;

    while (src[pos] != '\0' && !IsSpaceChar(src[pos]))
        pos++;

    int len = pos - start;

    if (len <= 0)
        return false;

    if (len >= maxlen)
        len = maxlen - 1;

    for (int i = 0; i < len; i++)
        token[i] = src[start + i];

    token[len] = '\0';

    return true;
}

bool AppendUtf8Codepoint(char[] output, int maxlen, int &pos, int codepoint)
{
    if (codepoint <= 0x7F)
    {
        if (pos + 1 >= maxlen)
            return false;

        output[pos++] = view_as<char>(codepoint);
    }
    else if (codepoint <= 0x7FF)
    {
        if (pos + 2 >= maxlen)
            return false;

        output[pos++] = view_as<char>(0xC0 | (codepoint >> 6));
        output[pos++] = view_as<char>(0x80 | (codepoint & 0x3F));
    }
    else if (codepoint <= 0xFFFF)
    {
        if (pos + 3 >= maxlen)
            return false;

        output[pos++] = view_as<char>(0xE0 | (codepoint >> 12));
        output[pos++] = view_as<char>(0x80 | ((codepoint >> 6) & 0x3F));
        output[pos++] = view_as<char>(0x80 | (codepoint & 0x3F));
    }
    else
    {
        if (pos + 4 >= maxlen)
            return false;

        output[pos++] = view_as<char>(0xF0 | (codepoint >> 18));
        output[pos++] = view_as<char>(0x80 | ((codepoint >> 12) & 0x3F));
        output[pos++] = view_as<char>(0x80 | ((codepoint >> 6) & 0x3F));
        output[pos++] = view_as<char>(0x80 | (codepoint & 0x3F));
    }

    output[pos] = '\0';

    return true;
}

bool IsValidUtf8String(const char[] input)
{
    int len = strlen(input);

    for (int i = 0; i < len;)
    {
        int b1 = input[i] & 0xFF;

        if (b1 <= 0x7F)
        {
            i++;
            continue;
        }

        int need;
        int codepoint;

        if (b1 >= 0xC2 && b1 <= 0xDF)
        {
            need      = 1;
            codepoint = b1 & 0x1F;
        }
        else if (b1 >= 0xE0 && b1 <= 0xEF)
        {
            need      = 2;
            codepoint = b1 & 0x0F;
        }
        else if (b1 >= 0xF0 && b1 <= 0xF4)
        {
            need      = 3;
            codepoint = b1 & 0x07;
        }
        else
        {
            return false;
        }

        if (i + need >= len)
            return false;

        for (int j = 1; j <= need; j++)
        {
            int bx = input[i + j] & 0xFF;

            if ((bx & 0xC0) != 0x80)
                return false;

            codepoint = (codepoint << 6) | (bx & 0x3F);
        }

        if ((need == 1 && codepoint < 0x80)
            || (need == 2 && codepoint < 0x800)
            || (need == 3 && codepoint < 0x10000))
            return false;

        if (codepoint >= 0xD800 && codepoint <= 0xDFFF)
            return false;

        i += need + 1;
    }

    return true;
}

void LoadGbkUnicodeMap()
{
    g_bGbkMapLoaded = false;

    for (int i = 0; i < 65536; i++)
        g_iGbkUnicodeMap[i] = 0;

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "data/gbk_unicode_map.txt");

    File file = OpenFile(path, "r");

    if (file == null)
    {
        LogError("[GBK] failed to open map file: %s", path);
        return;
    }

    char line[128];
    char token1[32];
    char token2[32];
    int  loaded = 0;

    while (!file.EndOfFile())
    {
        if (!file.ReadLine(line, sizeof(line)))
            break;

        TrimString(line);

        if (line[0] == '\0')
            continue;

        if (line[0] == '#' || line[0] == ';')
            continue;

        if (line[0] == '/' && line[1] == '/')
            continue;

        int pos = 0;

        if (!ReadNextToken(line, pos, token1, sizeof(token1)))
            continue;

        if (!ReadNextToken(line, pos, token2, sizeof(token2)))
            continue;

        int gbk;
        int unicode;

        if (!ParseHexInt(token1, gbk))
            continue;

        if (!ParseHexInt(token2, unicode))
            continue;

        if (gbk <= 0 || gbk > 0xFFFF)
            continue;

        if (unicode <= 0 || unicode > 0x10FFFF)
            continue;

        g_iGbkUnicodeMap[gbk] = unicode;
        loaded++;
    }

    delete file;

    g_bGbkMapLoaded = true;
}

void GbkToUtf8(const char[] input, char[] output, int maxlen)
{
    output[0] = '\0';

    int pos   = 0;
    int len   = strlen(input);

    for (int i = 0; i < len;)
    {
        int b1 = input[i] & 0xFF;

        if (b1 <= 0x7F)
        {
            if (!AppendUtf8Codepoint(output, maxlen, pos, b1))
                break;

            i++;
            continue;
        }

        if (i + 1 >= len)
        {
            if (!AppendUtf8Codepoint(output, maxlen, pos, '?'))
                break;

            break;
        }

        int b2      = input[i + 1] & 0xFF;
        int gbk     = (b1 << 8) | b2;
        int unicode = g_iGbkUnicodeMap[gbk];

        if (unicode == 0)
            unicode = '?';

        if (!AppendUtf8Codepoint(output, maxlen, pos, unicode))
            break;

        i += 2;
    }

    output[pos] = '\0';
}

void FormatDisplayVpkName(const char[] rawName, char[] output, int maxlen)
{
    if (IsValidUtf8String(rawName))
    {
        strcopy(output, maxlen, rawName);
        return;
    }

    if (!g_bGbkMapLoaded)
    {
        strcopy(output, maxlen, rawName);
        return;
    }

    GbkToUtf8(rawName, output, maxlen);
}

bool IsHexDigit(char c)
{
    return (c >= '0' && c <= '9')
        || (c >= 'A' && c <= 'F')
        || (c >= 'a' && c <= 'f');
}

bool IsVpkRuleStorageKey(const char[] key)
{
    int len = strlen(key);

    if (len <= 4 || ((len - 4) % 2) != 0)
        return false;

    if (key[0] != 'h' || key[1] != 'e' || key[2] != 'x' || key[3] != '_')
        return false;

    for (int i = 4; i < len; i++)
    {
        if (!IsHexDigit(key[i]))
            return false;
    }

    return true;
}

void BuildVpkRuleStorageKey(const char[] vpkName, char[] buffer, int maxlen)
{
    strcopy(buffer, maxlen, "hex_");

    int  pos = 4;
    int  len = strlen(vpkName);

    char piece[4];

    for (int i = 0; i < len && pos + 2 < maxlen; i++)
    {
        FormatEx(piece, sizeof(piece), "%02X", vpkName[i] & 0xFF);

        buffer[pos++] = piece[0];
        buffer[pos++] = piece[1];
    }

    buffer[pos] = '\0';
}

void ReadMemoryString(Address addr, char[] buffer, int size)
{
    int max = size - 1;
    int i   = 0;

    for (; i < max; i++)
    {
        buffer[i] = view_as<char>(LoadFromAddress(addr + view_as<Address>(i), NumberType_Int8));

        if (buffer[i] == '\0')
            return;
    }

    buffer[i] = '\0';
}

void InitGameData()
{
    CheckGameDataFile();

    Address         g_pVscriptMsgFunc;

    GameDataWrapper gd     = new GameDataWrapper(GAMEDATA);

    g_bIsLinuxOS           = gd.GetOffset("OS") == 1;
    g_pVscriptMsgFunc      = gd.GetAddress("msg_VScriptServerRunScriptForAllAddons");
    g_pAddonMetadataVector = gd.GetAddress("s_vecAddonMetadata");

    int offset             = g_bIsLinuxOS ? 232 : 165;
    int byteLength         = g_bIsLinuxOS ? 5 : 6;
    int byte               = LoadFromAddress(g_pVscriptMsgFunc + view_as<Address>(offset), NumberType_Int8);

    if ((byte == 0xE8 && g_bIsLinuxOS) || (byte == 0xFF && !g_bIsLinuxOS))
    {
        for (int i = 0; i < byteLength; i++)
            StoreToAddress(g_pVscriptMsgFunc + view_as<Address>(offset + i), 0x90, NumberType_Int8);
    }
    else if (byte != 0x90)
    {
        PrintToServer("Falied to Patch msg_VScriptServerRunScriptForAllAddons");
    }

    delete gd.CreateDetourOrFail("KeyValues::GetString", true, _, DTR_KeyValues_GetString_Post);
    delete gd.CreateDetourOrFail("FileSystem_UpdateAddonSearchPaths", true, DTR_PreFileSystem_UpdateAddonSearchPaths, DTR_PostFileSystem_UpdateAddonSearchPaths);
    delete gd.CreateDetourOrFail("LoadAddonListFile", true, _, DTR_LoadAddonListFile_Post);
    delete gd.CreateDetourOrFail("CServerGameDLL::GetMatchmakingGameData", true, DTR_PreCServerGameDLL_GetMatchmakingGameData);
    delete gd.CreateDetourOrFail("CMatchExtL4D::ParseMissionFromFile", true, DTR_PreParseMissionFromFile, DTR_ParseMissionFromFile_Post);
    delete gd.CreateDetourOrFail("CDirectorChallengeMode::InitScriptsNonVirtual", true, DTR_PreCDirectorChallengeMode_InitScriptsNonVirtual, DTR_PostCDirectorChallengeMode_InitScriptsNonVirtual);
    delete gd.CreateDetourOrFail("CScriptConvarAccessor::SetValue", true, DTR_PreCScriptConvarAccessor_SetValue);
    delete gd.CreateDetourOrFail("VScriptServerRunScriptForAllAddons", true, DTR_PreVScriptServerRunScriptForAllAddons, DTR_PostVScriptServerRunScriptForAllAddons);

    delete gd;
}

void CheckGameDataFile()
{
    char sPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sPath, sizeof(sPath), "gamedata/%s.txt", GAMEDATA);
    File hFile;
    bool bNeedUpdate = false;
    if (FileExists(sPath))
    {
        char buffer1[64], buffer2[64];
        hFile = OpenFile(sPath, "r", false);
        if (hFile != null)
        {
            if (hFile.ReadLine(buffer1, sizeof(buffer1)))
            {
                FormatEx(buffer2, sizeof(buffer2), "//%d\n", GAMEDATA_VERSION);
                if (!StrEqual(buffer1, buffer2, false))
                    bNeedUpdate = true;
            }
            else
            {
                bNeedUpdate = true;
            }
            delete hFile;
            hFile = null;
        }
    }
    else
    {
        bNeedUpdate = true;
    }

    if (bNeedUpdate)
    {
        hFile = OpenFile(sPath, "w", false);
        if (hFile != null)
        {
            hFile.WriteLine("//%d", GAMEDATA_VERSION);
            hFile.WriteLine("\"Games\"");
            hFile.WriteLine("{");
            hFile.WriteLine("	\"left4dead2\"");
            hFile.WriteLine("	{");
            hFile.WriteLine("		\"Addresses\"");
            hFile.WriteLine("		{");
            hFile.WriteLine("			\"s_vecAddonMetadata\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("			    \"linux\"");
            hFile.WriteLine("			    {");
            hFile.WriteLine("				    \"signature\"		\"s_vecAddonMetadata\"");
            hFile.WriteLine("			    }");
            hFile.WriteLine("			    \"windows\"");
            hFile.WriteLine("			    {");
            hFile.WriteLine("				    \"signature\"		\"show_addon_metadata\"");
            hFile.WriteLine("				    \"read\"	    \"49\"");
            hFile.WriteLine("			    }");
            hFile.WriteLine("			}");
            hFile.WriteLine("			\"msg_VScriptServerRunScriptForAllAddons\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				  \"signature\"		\"VScriptServerRunScriptForAllAddons\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("		}");
            hFile.WriteLine("");
            hFile.WriteLine("		\"Offsets\"");
            hFile.WriteLine("		{");
            hFile.WriteLine("			\"OS\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"linux\"		\"1\"");
            hFile.WriteLine("				\"windows\"	    \"0\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("		}");
            hFile.WriteLine("");
            hFile.WriteLine("		\"Signatures\"");
            hFile.WriteLine("		{");
            hFile.WriteLine("			\"CDirectorChallengeMode::InitScriptsNonVirtual\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"library\" \"server\"");
            hFile.WriteLine("				\"linux\"		\"@_ZN22CDirectorChallengeMode21InitScriptsNonVirtualEv\"");
            hFile.WriteLine("				\"windows\"	\"\\x55\\x8B\\xEC\\x83\\xEC\\x10\\x56\\x8B\\xF1\\x8B\\x0D\\x2A\\x2A\\x2A\\x2A\\xE8\\x2A\\x2A\\x2A\\x2A\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"CServerGameDLL::GetMatchmakingGameData\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"library\" \"server\"");
            hFile.WriteLine("				\"linux\"		\"@_ZN14CServerGameDLL22GetMatchmakingGameDataEPcj\"");
            hFile.WriteLine("				\"windows\"	\"\\x55\\x8B\\xEC\\x56\\x8B\\x75\\x08\\x57\\x8B\\x7D\\x0C\\x68\\x2A\\x2A\\x2A\\x2A\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"CMatchExtL4D::ParseMissionFromFile\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"library\" \"matchmaking_ds\"");
            hFile.WriteLine("				\"linux\"		\"@_ZN12CMatchExtL4D20ParseMissionFromFileEPKcby\"");
            hFile.WriteLine("				\"windows\"	\"\\x55\\x8B\\xEC\\x81\\xEC\\x64\\x04\\x00\\x00\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"KeyValues::GetString\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"library\" \"matchmaking_ds\"");
            hFile.WriteLine("				\"linux\"		\"@_ZN9KeyValues9GetStringEPKcS1_\"");
            hFile.WriteLine("				\"windows\"	\"\\x55\\x8B\\xEC\\x81\\xEC\\x44\\x02\\x00\\x00\\xA1\\x2A\\x2A\\x2A\\x2A\\x33\\xC5\\x89\\x45\\xFC\\x53\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"s_vecAddonMetadata\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"library\" \"engine\"");
            hFile.WriteLine("				\"linux\"		\"@_ZL18s_vecAddonMetadata\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"show_addon_metadata\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"library\" \"engine\"");
            hFile.WriteLine("				\"windows\"	\"\\x83\\x3D\\x2A\\x2A\\x2A\\x2A\\x00\\x53\\x56\\x8B\\x35\\x2A\\x2A\\x2A\\x2A\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"CScriptConvarAccessor::SetValue\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"library\" \"server\"");
            hFile.WriteLine("				\"linux\"		\"@_ZN21CScriptConvarAccessor8SetValueEPKc12CVariantBaseI24CVariantDefaultAllocatorE\"");
            hFile.WriteLine("				\"windows\"	\"\\x55\\x8B\\xEC\\x83\\xEC\\x08\\x56\\x8B\\x75\\x08\\x56\\x8D\\x4D\\xF8\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"VScriptServerRunScriptForAllAddons\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"library\" \"server\"");
            hFile.WriteLine("				\"linux\"		\"@_Z34VScriptServerRunScriptForAllAddonsPKcP9HSCRIPT__b\"");
            hFile.WriteLine("				\"windows\"	\"\\x55\\x8B\\xEC\\x81\\xEC\\x1C\\x01\\x00\\x00\\xA1\\x2A\\x2A\\x2A\\x2A\\x33\\xC5\\x89\\x45\\xFC\\x8B\\x45\\x08\\x53\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"FileSystem_UpdateAddonSearchPaths\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"library\" \"engine\"");
            hFile.WriteLine("				\"linux\"		\"@_ZL33FileSystem_UpdateAddonSearchPathsv\"");
            hFile.WriteLine("				\"windows\"	\"\\x55\\x8B\\xEC\\x81\\xEC\\x2C\\x03\\x00\\x00\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"LoadAddonListFile\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"library\" \"engine\"");
            hFile.WriteLine("				\"linux\"		\"@_Z17LoadAddonListFilePKcRP9KeyValues\"");
            hFile.WriteLine("				\"windows\"	\"\\x55\\x8B\\xEC\\x81\\xEC\\x18\\x03\\x00\\x00\\xA1\\x2A\\x2A\\x2A\\x2A\\x33\\xC5\\x89\\x45\\xFC\\x8B\\x45\\x08\\x56\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("		}");
            hFile.WriteLine("");
            hFile.WriteLine("		\"Functions\"");
            hFile.WriteLine("		{");
            hFile.WriteLine("			\"CDirectorChallengeMode::InitScriptsNonVirtual\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"signature\" \"CDirectorChallengeMode::InitScriptsNonVirtual\"");
            hFile.WriteLine("				\"callconv\" \"thiscall\"");
            hFile.WriteLine("				\"return\" \"int\"");
            hFile.WriteLine("				\"this\" \"address\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"KeyValues::GetString\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"signature\" \"KeyValues::GetString\"");
            hFile.WriteLine("				\"callconv\" \"thiscall\"");
            hFile.WriteLine("				\"return\" \"charptr\"");
            hFile.WriteLine("				\"this\" \"address\"");
            hFile.WriteLine("				\"arguments\"");
            hFile.WriteLine("				{");
            hFile.WriteLine("					\"src\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"charptr\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("					\"dest\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"charptr\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("				}");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"CMatchExtL4D::ParseMissionFromFile\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"signature\" \"CMatchExtL4D::ParseMissionFromFile\"");
            hFile.WriteLine("				\"callconv\" \"thiscall\"");
            hFile.WriteLine("				\"return\" \"int\"");
            hFile.WriteLine("				\"this\" \"address\"");
            hFile.WriteLine("				\"arguments\"");
            hFile.WriteLine("				{");
            hFile.WriteLine("			        \"linux\"");
            hFile.WriteLine("			        {");
            hFile.WriteLine("					    \"src\"");
            hFile.WriteLine("					    {");
            hFile.WriteLine("						    \"type\" \"charptr\"");
            hFile.WriteLine("					    }");
            hFile.WriteLine("					    \"a1\"");
            hFile.WriteLine("					    {");
            hFile.WriteLine("						    \"type\" \"int\"");
            hFile.WriteLine("					    }");
            hFile.WriteLine("					    \"a2\"");
            hFile.WriteLine("					    {");
            hFile.WriteLine("						    \"type\" \"int\"");
            hFile.WriteLine("					    }");
            hFile.WriteLine("			        }");
            hFile.WriteLine("			        \"windows\"");
            hFile.WriteLine("			        {");
            hFile.WriteLine("					    \"src\"");
            hFile.WriteLine("					    {");
            hFile.WriteLine("						    \"type\" \"charptr\"");
            hFile.WriteLine("					    }");
            hFile.WriteLine("					    \"a3\"");
            hFile.WriteLine("					    {");
            hFile.WriteLine("						    \"type\" \"charptr\"");
            hFile.WriteLine("					    }");
            hFile.WriteLine("					    \"a1\"");
            hFile.WriteLine("					    {");
            hFile.WriteLine("						    \"type\" \"int\"");
            hFile.WriteLine("					    }");
            hFile.WriteLine("					    \"a2\"");
            hFile.WriteLine("					    {");
            hFile.WriteLine("						    \"type\" \"int\"");
            hFile.WriteLine("					    }");
            hFile.WriteLine("			        }");
            hFile.WriteLine("				}");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"VScriptServerRunScriptForAllAddons\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"signature\" \"VScriptServerRunScriptForAllAddons\"");
            hFile.WriteLine("				\"callconv\" \"cdecl\"");
            hFile.WriteLine("				\"return\" \"int\"");
            hFile.WriteLine("				\"this\" \"ignore\"");
            hFile.WriteLine("				\"arguments\"");
            hFile.WriteLine("				{");
            hFile.WriteLine("					\"name\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"charptr\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("					\"length\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"int\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("					\"bool\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"bool\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("				}");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"FileSystem_UpdateAddonSearchPaths\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"signature\" \"FileSystem_UpdateAddonSearchPaths\"");
            hFile.WriteLine("				\"callconv\" \"cdecl\"");
            hFile.WriteLine("				\"return\" \"int\"");
            hFile.WriteLine("				\"this\" \"ignore\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"LoadAddonListFile\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"signature\" \"LoadAddonListFile\"");
            hFile.WriteLine("				\"callconv\" \"cdecl\"");
            hFile.WriteLine("				\"return\" \"int\"");
            hFile.WriteLine("				\"this\" \"ignore\"");
            hFile.WriteLine("				\"arguments\"");
            hFile.WriteLine("				{");
            hFile.WriteLine("					\"name\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"charptr\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("					\"kvptr\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"objectptr\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("				}");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"CServerGameDLL::GetMatchmakingGameData\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"signature\" \"CServerGameDLL::GetMatchmakingGameData\"");
            hFile.WriteLine("				\"callconv\" \"thiscall\"");
            hFile.WriteLine("				\"return\" \"int\"");
            hFile.WriteLine("				\"this\" \"ignore\"");
            hFile.WriteLine("				\"arguments\"");
            hFile.WriteLine("				{");
            hFile.WriteLine("					\"name\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"charptr\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("					\"length\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"int\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("				}");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("			\"CScriptConvarAccessor::SetValue\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"signature\" \"CScriptConvarAccessor::SetValue\"");
            hFile.WriteLine("				\"callconv\" \"thiscall\"");
            hFile.WriteLine("				\"return\" \"int\"");
            hFile.WriteLine("				\"this\" \"ignore\"");
            hFile.WriteLine("				\"arguments\"");
            hFile.WriteLine("				{");
            hFile.WriteLine("			        \"linux\"");
            hFile.WriteLine("			        {");
            hFile.WriteLine("					    \"a1\"");
            hFile.WriteLine("					    {");
            hFile.WriteLine("						    \"type\" \"charptr\"");
            hFile.WriteLine("					    }");
            hFile.WriteLine("					    \"a2\"");
            hFile.WriteLine("					    {");
            hFile.WriteLine("						    \"type\" \"objectptr\"");
            hFile.WriteLine("					    }");
            hFile.WriteLine("			        }");
            hFile.WriteLine("			        \"windows\"");
            hFile.WriteLine("			        {");
            hFile.WriteLine("					    \"a1\"");
            hFile.WriteLine("					    {");
            hFile.WriteLine("						    \"type\" \"charptr\"");
            hFile.WriteLine("					    }");
            hFile.WriteLine("					    \"a2\"");
            hFile.WriteLine("					    {");
            hFile.WriteLine("						    \"type\" \"float\"");
            hFile.WriteLine("					    }");
            hFile.WriteLine("					    \"a3\"");
            hFile.WriteLine("					    {");
            hFile.WriteLine("						    \"type\" \"int\"");
            hFile.WriteLine("					    }");
            hFile.WriteLine("					    \"a4\"");
            hFile.WriteLine("					    {");
            hFile.WriteLine("						    \"type\" \"int\"");
            hFile.WriteLine("					    }");
            hFile.WriteLine("					    \"a5\"");
            hFile.WriteLine("					    {");
            hFile.WriteLine("						    \"type\" \"int\"");
            hFile.WriteLine("					    }");
            hFile.WriteLine("			        }");
            hFile.WriteLine("				}");
            hFile.WriteLine("			}");
            hFile.WriteLine("		}");
            hFile.WriteLine("	}");
            hFile.WriteLine("}");

            FlushFile(hFile);
            delete hFile;
            hFile = null;
        }
    }

    delete hFile;
}

