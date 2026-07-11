#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>
#include <l4d2_source_keyvalues>

#define GAMEDATA             "l4d2_vscript_purifier_v2"
#define GAMEDATA_VERSION     17
#define VPK_RULE_NONE        0
#define VPK_RULE_WHITELIST   1
#define VPK_RULE_BLACKLIST   2
#define VPK_RULE_KEY_MAX     600
#define VPK_BINDING_KEY_MAX  1300
#define VPK_BINDING_DONE_KEY "__done"

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
    g_hLastFilterTargets,
    g_hBindingContentSelection[MAXPLAYERS + 1],
    g_hBindingMapSelection[MAXPLAYERS + 1];

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
    g_bAddonListRestorePending,
    g_bAddonFilterMapReady,
    g_bExecutingUpdateAddonPaths,
    g_bVScriptPairRestorePending;

int
    g_iCvarSwitch,
    g_iCvarRestore,
    g_iBlacklistedRuleCount,
    g_iAddonListLoadCallCount,
    g_iVScriptScriptedModeCount,
    g_iVScriptDirectorBaseCount,
    g_iGbkUnicodeMap[65536];

StringMap
    g_hVpkRules,
    g_hVpkBindings;

char
    CurrentMapName[128],
    g_sVpkRulesPath[PLATFORM_MAX_PATH],
    g_sPendingDeleteBinding[MAXPLAYERS + 1][VPK_BINDING_KEY_MAX];

public Plugin myinfo =
{
    name        = "l4d2_vscript_purifier_v2",
    author      = "洛琪, Forgetest",
    description = "防止地图脚本污染",
    version     = "2.4",
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
        1.0);

    g_hCvarRestore = CreateConVar(
        "l4d2_vscript_cvarRestore_v2",
        "1",
        "脚本修改 cvar 的处理方式：0=不处理，1=过关/回合开始时恢复默认值，2=直接拦截脚本修改请求。",
        FCVAR_NOTIFY,
        true,
        0.0,
        true,
        2.0);

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

public void OnMapEnd()
{
    ResetVScriptPairRestoreState();
    g_bAddonFilterMapReady = false;
    RestoreAddonListFilterNow("OnMapEnd");
}

public void OnServerEnterHibernation()
{
    g_bAddonFilterMapReady = false;
    RestoreAddonListFilterNow("OnServerEnterHibernation");
}

public void OnPluginEnd()
{
    g_bAddonFilterMapReady = false;

    delete g_hVpkRules;
    g_hVpkRules = null;

    ClearVpkBindings();

    for (int i = 1; i <= MaxClients; i++)
        ClearClientBindingSelection(i);

    RestoreAddonListFilterNow("OnPluginEnd");
}

public void OnClientDisconnect(int client)
{
    ClearClientBindingSelection(client);
}

public void OnMapInit(const char[] mapName)
{
    g_bAddonFilterMapReady = false;
    ResetVScriptPairRestoreState();

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

    g_bAddonFilterMapReady = true;
    g_bAllowCall           = true;

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

void ResetVScriptPairRestoreState()
{
    g_iVScriptScriptedModeCount  = 0;
    g_iVScriptDirectorBaseCount  = 0;
    g_bVScriptPairRestorePending = false;
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
    char key[64];

    if (!DHookIsNullParam(hParams, 1))
        DHookGetParamString(hParams, 1, key, sizeof(key));

    ApplyAddonListFilter("DTR_PreVScriptServerRunScriptForAllAddons");

    if (StrEqual(key, "scriptedmode", false))
        g_iVScriptScriptedModeCount++;
    else if (StrEqual(key, "director_base", false))
        g_iVScriptDirectorBaseCount++;

    if (g_iVScriptScriptedModeCount >= 2 && g_iVScriptDirectorBaseCount >= 2)
        g_bVScriptPairRestorePending = true;

    return MRES_Ignored;
}

MRESReturn DTR_PostVScriptServerRunScriptForAllAddons(DHookReturn hReturn, DHookParam hParams)
{
    if (!g_bVScriptPairRestorePending)
        return MRES_Ignored;

    if (RestoreAddonListFilterNow("DTR_PostVScriptServerRunScriptForAllAddons scriptedmode/director_base x2"))
    {
        ResetVScriptPairRestoreState();
        g_bAddonFilterMapReady = false;
    }
    else
    {
        g_bVScriptPairRestorePending = false;
    }

    return MRES_Ignored;
}

MRESReturn DTR_PreCDirectorChallengeMode_InitScriptsNonVirtual(DHookReturn hReturn)
{
    ApplyAddonListFilter("DTR_PreCDirectorChallengeMode_InitScriptsNonVirtual");
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

    if (hReturn.Value == 0 || pKv == Address_Null)
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

MRESReturn DTR_PreCScriptConvarAccessor_SetValue(DHookReturn hReturn, DHookParam hParams)
{
    if (g_iCvarRestore == 2)
    {
        hReturn.Value = 0;
        return MRES_Supercede;
    }

    if (g_iCvarRestore != 1)
        return MRES_Ignored;

    char cvarName[64];
    DHookGetParamString(hParams, 1, cvarName, sizeof(cvarName));

    if (g_hChangedCvars == null)
        g_hChangedCvars = new ArrayList(ByteCountToCells(64));

    g_hChangedCvars.PushString(cvarName);

    return MRES_Ignored;
}

bool ApplyAddonListFilter(const char[] reason)
{
    if (!g_bAddonFilterMapReady)
        return false;

    if (g_iCvarSwitch <= 0)
        return false;

    // 广西南宁 m1换到m2 会导致崩溃 排查后发现不是插件和地图的问题，好像是游戏本身的update_addon_path和地图更深层次的反应，因此插件在南宁地图不执行操作
    if (StrContains(CurrentMapName, "nanningcity", false) != -1)
        return false;

    if ((g_hBlockedMissionVpks == null || g_hBlockedMissionVpks.Length == 0) && !HasBlacklistedVpkRules())
        return false;

    if (g_bAddonListFilterApplied && ArrayListStringSetEquals(g_hLastFilterTargets, g_hBlockedMissionVpks))
    {
        return true;
    }

    g_bAddonListFilterArmed    = true;
    g_bAddonListRestorePending = false;

    ResetVScriptPairRestoreState();

    SaveLastFilterTargets();

    if (!ExecuteUpdateAddonPaths(reason))
    {
        g_bAddonListFilterArmed = false;
        return false;
    }

    g_bAddonListFilterApplied = true;

    return true;
}

bool RestoreAddonListFilterNow(const char[] reason)
{
    if (g_bAddonListRestorePending)
        return false;

    if (!g_bAddonListFilterApplied && !g_bAddonListFilterArmed)
        return false;

    g_bAddonListFilterArmed    = false;
    g_bAddonListRestorePending = true;

    if (!ExecuteUpdateAddonPaths(reason))
    {
        g_bAddonListRestorePending = false;
        return false;
    }

    return true;
}

void ApplyAddonListKeyValuesFilter(SourceKeyValues kv)
{
    if (kv.IsNull())
    {
        return;
    }

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

    if (IsVpkBoundToAnyMapList(vpkName, g_hAllowedMapVpks))
        return false;

    if (ArrayListHasString(g_hBlockedMissionVpks, vpkName, false))
        return true;

    if (IsVpkBoundToAnyMapList(vpkName, g_hBlockedMissionVpks))
        return true;

    return false;
}

bool ExecuteUpdateAddonPaths(const char[] reason)
{
    if (g_bExecutingUpdateAddonPaths)
        return false;

    g_bExecutingUpdateAddonPaths = true;
    ServerCommand("update_addon_paths");
    ServerExecute();
    LogMessage("update addon paths reason: %s Time %f", reason, GetEngineTime());
    g_bExecutingUpdateAddonPaths = false;

    return true;
}

public Action Command_VpkList(int client, int args)
{
    if (!IsValidMenuClient(client))
        return Plugin_Handled;

    DisplayVpkCategoryMenu(client);
    return Plugin_Handled;
}

void DisplayVpkCategoryMenu(int client)
{
    if (!IsValidMenuClient(client))
        return;

    Menu menu = new Menu(MenuHandler_VpkCategory);
    menu.SetTitle("VPK 黑白名单管理");

    menu.AddItem("mission", "地图 VPK");
    menu.AddItem("content", "普通 VPK");
    menu.AddItem("binding", "VPK 绑定");

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_VpkCategory(Menu menu, MenuAction action, int client, int item)
{
    if ((action == MenuAction_Select || action == MenuAction_Cancel) && !IsValidMenuClient(client))
        return 0;

    if (action == MenuAction_Select)
    {
        char info[32];
        menu.GetItem(item, info, sizeof(info));

        if (StrEqual(info, "mission", false))
            DisplayVpkRuleMenu(client, true);
        else if (StrEqual(info, "content", false))
            DisplayVpkRuleMenu(client, false);
        else if (StrEqual(info, "binding", false))
            DisplayVpkBindingIntroPanel(client);
    }
    else if (action == MenuAction_Cancel)
    {
        PrintToChat(client, "\x04[VPK]\x01 修改后下次换图后生效。");
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

void DisplayVpkRuleMenu(int client, bool missionVpk)
{
    if (!IsValidMenuClient(client))
        return;
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
    if ((action == MenuAction_Select || action == MenuAction_Cancel) && !IsValidMenuClient(client))
        return 0;

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
            PrintToChat(client, "\x04[VPK]\x01 修改后下次换图后生效。");
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

void DisplayVpkBindingIntroPanel(int client)
{
    if (!IsValidMenuClient(client))
        return;
    Panel panel = new Panel();

    panel.SetTitle("VPK 绑定说明");
    panel.DrawText(" ");
    panel.DrawText("用于解决一个地图由多个 VPK 构成，");
    panel.DrawText("但 mission 文件只存在于其中一个 VPK 的情况。");
    panel.DrawText(" ");
    panel.DrawText("绑定后，普通 VPK 会被视为指定地图 VPK 的一部分。");
    panel.DrawText("过滤时仍按地图 VPK 逻辑处理。");
    panel.DrawText(" ");
    panel.DrawText("白名单 / 黑名单仍然拥有最高优先级。");
    panel.DrawText(" ");

    panel.DrawItem("进入绑定菜单");
    panel.DrawItem("返回");

    panel.Send(client, PanelHandler_VpkBindingIntro, MENU_TIME_FOREVER);

    delete panel;
}

public int PanelHandler_VpkBindingIntro(Menu menu, MenuAction action, int client, int item)
{
    if (action != MenuAction_Select)
        return 0;

    if (!IsValidMenuClient(client))
        return 0;

    if (item == 1)
        DisplayVpkBindingMainMenu(client);
    else
        DisplayVpkCategoryMenu(client);

    return 0;
}

void DisplayVpkBindingMainMenu(int client)
{
    if (!IsValidMenuClient(client))
        return;
    Menu menu = new Menu(MenuHandler_VpkBindingMain);
    menu.SetTitle("VPK 绑定管理");

    menu.AddItem("add", "新增绑定");
    menu.AddItem("view", "查看 / 取消绑定");

    menu.ExitBackButton = true;
    menu.ExitButton     = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_VpkBindingMain(Menu menu, MenuAction action, int client, int item)
{
    if ((action == MenuAction_Select || action == MenuAction_Cancel) && !IsValidMenuClient(client))
        return 0;

    if (action == MenuAction_Select)
    {
        char info[32];
        menu.GetItem(item, info, sizeof(info));

        if (StrEqual(info, "add", false))
        {
            ClearClientBindingSelection(client);
            EnsureClientBindingSelection(client);
            DisplayVpkBindingContentSelectMenu(client);
        }
        else if (StrEqual(info, "view", false))
        {
            DisplayVpkBindingListMenu(client);
        }
    }
    else if (action == MenuAction_Cancel)
    {
        if (item == MenuCancel_ExitBack)
            DisplayVpkCategoryMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

void DisplayVpkBindingContentSelectMenu(int client)
{
    if (!IsValidMenuClient(client))
        return;
    EnsureClientBindingSelection(client);

    Menu menu = new Menu(MenuHandler_VpkBindingContentSelect);
    menu.SetTitle("第一步：选择普通 VPK，可多选");

    if (g_hBindingContentSelection[client].Length > 0)
        menu.AddItem(VPK_BINDING_DONE_KEY, "下一步：选择地图 VPK");
    else
        menu.AddItem(VPK_BINDING_DONE_KEY, "下一步：选择地图 VPK", ITEMDRAW_DISABLED);

    if (g_hContentList == null || g_hContentList.Length == 0)
    {
        menu.AddItem("", "当前没有扫描到普通 VPK", ITEMDRAW_DISABLED);
    }
    else
    {
        char vpkName[256];
        char displayName[256];
        char display[300];

        for (int i = 0; i < g_hContentList.Length; i++)
        {
            g_hContentList.GetString(i, vpkName, sizeof(vpkName));
            FormatDisplayVpkName(vpkName, displayName, sizeof(displayName));

            if (ArrayListHasString(g_hBindingContentSelection[client], vpkName, false))
                FormatEx(display, sizeof(display), "[已选] %s", displayName);
            else
                FormatEx(display, sizeof(display), "[未选] %s", displayName);

            menu.AddItem(vpkName, display);
        }
    }

    menu.ExitBackButton = true;
    menu.ExitButton     = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_VpkBindingContentSelect(Menu menu, MenuAction action, int client, int item)
{
    if ((action == MenuAction_Select || action == MenuAction_Cancel) && !IsValidMenuClient(client))
        return 0;

    if (action == MenuAction_Select)
    {
        char info[256];
        menu.GetItem(item, info, sizeof(info));

        if (StrEqual(info, VPK_BINDING_DONE_KEY, false))
        {
            DisplayVpkBindingMapSelectMenu(client);
            return 0;
        }

        EnsureClientBindingSelection(client);
        ToggleArrayListString(g_hBindingContentSelection[client], info);
        DisplayVpkBindingContentSelectMenu(client);
    }
    else if (action == MenuAction_Cancel)
    {
        if (item == MenuCancel_ExitBack)
            DisplayVpkBindingMainMenu(client);
        else
            ClearClientBindingSelection(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

void DisplayVpkBindingMapSelectMenu(int client)
{
    if (!IsValidMenuClient(client))
        return;
    EnsureClientBindingSelection(client);

    Menu menu = new Menu(MenuHandler_VpkBindingMapSelect);
    menu.SetTitle("第二步：选择绑定的地图 VPK，可多选");

    if (g_hBindingMapSelection[client].Length > 0)
        menu.AddItem(VPK_BINDING_DONE_KEY, "完成绑定");
    else
        menu.AddItem(VPK_BINDING_DONE_KEY, "完成绑定", ITEMDRAW_DISABLED);

    ArrayList mapList = new ArrayList(ByteCountToCells(256));
    char      vpkName[256];

    if (g_hAllowedMapVpks != null)
    {
        for (int i = 0; i < g_hAllowedMapVpks.Length; i++)
        {
            g_hAllowedMapVpks.GetString(i, vpkName, sizeof(vpkName));
            PushStringUnique(mapList, vpkName);
        }
    }

    if (g_hBlockedMissionVpks != null)
    {
        for (int i = 0; i < g_hBlockedMissionVpks.Length; i++)
        {
            g_hBlockedMissionVpks.GetString(i, vpkName, sizeof(vpkName));
            PushStringUnique(mapList, vpkName);
        }
    }

    if (mapList.Length == 0)
    {
        menu.AddItem("", "当前没有扫描到地图 VPK", ITEMDRAW_DISABLED);
    }
    else
    {
        char displayName[256];
        char display[300];

        for (int i = 0; i < mapList.Length; i++)
        {
            mapList.GetString(i, vpkName, sizeof(vpkName));
            FormatDisplayVpkName(vpkName, displayName, sizeof(displayName));

            if (ArrayListHasString(g_hBindingMapSelection[client], vpkName, false))
                FormatEx(display, sizeof(display), "[已选] %s", displayName);
            else
                FormatEx(display, sizeof(display), "[未选] %s", displayName);

            menu.AddItem(vpkName, display);
        }
    }

    delete mapList;

    menu.ExitBackButton = true;
    menu.ExitButton     = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_VpkBindingMapSelect(Menu menu, MenuAction action, int client, int item)
{
    if ((action == MenuAction_Select || action == MenuAction_Cancel) && !IsValidMenuClient(client))
        return 0;

    if (action == MenuAction_Select)
    {
        char info[256];
        menu.GetItem(item, info, sizeof(info));

        if (StrEqual(info, VPK_BINDING_DONE_KEY, false))
        {
            SaveSelectedVpkBindings(client);
            ClearClientBindingSelection(client);
            DisplayVpkBindingMainMenu(client);
            return 0;
        }

        EnsureClientBindingSelection(client);
        ToggleArrayListString(g_hBindingMapSelection[client], info);
        DisplayVpkBindingMapSelectMenu(client);
    }
    else if (action == MenuAction_Cancel)
    {
        if (item == MenuCancel_ExitBack)
            DisplayVpkBindingContentSelectMenu(client);
        else
            ClearClientBindingSelection(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

void SaveSelectedVpkBindings(int client)
{
    char contentVpk[256];
    char mapVpk[256];

    int  count = 0;

    for (int i = 0; i < g_hBindingContentSelection[client].Length; i++)
    {
        g_hBindingContentSelection[client].GetString(i, contentVpk, sizeof(contentVpk));

        for (int j = 0; j < g_hBindingMapSelection[client].Length; j++)
        {
            g_hBindingMapSelection[client].GetString(j, mapVpk, sizeof(mapVpk));
            SetVpkBinding(contentVpk, mapVpk, true);
            count++;
        }
    }

    PrintToChat(client, "\x04[VPK]\x01 已新增 %d 条 VPK 绑定。", count);
}

void DisplayVpkBindingListMenu(int client)
{
    if (!IsValidMenuClient(client))
        return;
    Menu menu = new Menu(MenuHandler_VpkBindingList);
    menu.SetTitle("查看 / 取消 VPK 绑定");

    if (g_hVpkBindings == null)
    {
        menu.AddItem("", "当前没有绑定关系", ITEMDRAW_DISABLED);
    }
    else
    {
        StringMapSnapshot snapshot = g_hVpkBindings.Snapshot();

        if (snapshot.Length == 0)
        {
            menu.AddItem("", "当前没有绑定关系", ITEMDRAW_DISABLED);
        }
        else
        {
            char bindingKey[VPK_BINDING_KEY_MAX];
            char contentVpk[256];
            char mapVpk[256];
            char contentDisplay[256];
            char mapDisplay[256];
            char display[600];

            for (int i = 0; i < snapshot.Length; i++)
            {
                snapshot.GetKey(i, bindingKey, sizeof(bindingKey));

                if (!ParseVpkBindingStorageKey(bindingKey, contentVpk, sizeof(contentVpk), mapVpk, sizeof(mapVpk)))
                    continue;

                FormatDisplayVpkName(contentVpk, contentDisplay, sizeof(contentDisplay));
                FormatDisplayVpkName(mapVpk, mapDisplay, sizeof(mapDisplay));

                FormatEx(display, sizeof(display), "%s -> %s", contentDisplay, mapDisplay);
                menu.AddItem(bindingKey, display);
            }
        }

        delete snapshot;
    }

    menu.ExitBackButton = true;
    menu.ExitButton     = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_VpkBindingList(Menu menu, MenuAction action, int client, int item)
{
    if ((action == MenuAction_Select || action == MenuAction_Cancel) && !IsValidMenuClient(client))
        return 0;

    if (action == MenuAction_Select)
    {
        char bindingKey[VPK_BINDING_KEY_MAX];
        menu.GetItem(item, bindingKey, sizeof(bindingKey));

        strcopy(g_sPendingDeleteBinding[client], sizeof(g_sPendingDeleteBinding[]), bindingKey);
        DisplayVpkBindingDeleteConfirmPanel(client);
    }
    else if (action == MenuAction_Cancel)
    {
        if (item == MenuCancel_ExitBack)
            DisplayVpkBindingMainMenu(client);
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

void DisplayVpkBindingDeleteConfirmPanel(int client)
{
    if (!IsValidMenuClient(client))
        return;

    char contentVpk[256];
    char mapVpk[256];
    char contentDisplay[256];
    char mapDisplay[256];

    ParseVpkBindingStorageKey(
        g_sPendingDeleteBinding[client],
        contentVpk,
        sizeof(contentVpk),
        mapVpk,
        sizeof(mapVpk));

    FormatDisplayVpkName(contentVpk, contentDisplay, sizeof(contentDisplay));
    FormatDisplayVpkName(mapVpk, mapDisplay, sizeof(mapDisplay));

    Panel panel = new Panel();
    panel.SetTitle("取消 VPK 绑定");
    panel.DrawText(" ");
    panel.DrawText(contentDisplay);
    panel.DrawText("绑定到：");
    panel.DrawText(mapDisplay);
    panel.DrawText(" ");

    panel.DrawItem("确认取消");
    panel.DrawItem("返回");

    panel.Send(client, PanelHandler_VpkBindingDeleteConfirm, MENU_TIME_FOREVER);

    delete panel;
}

public int PanelHandler_VpkBindingDeleteConfirm(Menu menu, MenuAction action, int client, int item)
{
    if (action != MenuAction_Select)
        return 0;

    if (!IsValidMenuClient(client))
        return 0;

    if (item == 1)
    {
        if (g_hVpkBindings != null && g_sPendingDeleteBinding[client][0] != '\0')
        {
            g_hVpkBindings.Remove(g_sPendingDeleteBinding[client]);
            SaveVpkRulesCache();

            PrintToChat(client, "\x04[VPK]\x01 已取消该 VPK 绑定。");
        }

        g_sPendingDeleteBinding[client][0] = '\0';
        DisplayVpkBindingListMenu(client);
    }
    else
    {
        DisplayVpkBindingListMenu(client);
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
    ClearVpkBindings();
    g_hVpkRules             = new StringMap();
    g_hVpkBindings          = new StringMap();

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

    if (kv.JumpToKey("Bindings"))
    {
        if (kv.GotoFirstSubKey())
        {
            char bindingKey[VPK_BINDING_KEY_MAX];

            do
            {
                kv.GetSectionName(bindingKey, sizeof(bindingKey));

                if (IsVpkBindingStorageKey(bindingKey))
                    g_hVpkBindings.SetValue(bindingKey, 1);
            }
            while (kv.GotoNextKey());

            kv.GoBack();
        }

        kv.GoBack();
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

    if (g_hVpkBindings != null && kv.JumpToKey("Bindings", true))
    {
        StringMapSnapshot bindingSnapshot = g_hVpkBindings.Snapshot();
        char              bindingKey[VPK_BINDING_KEY_MAX];

        for (int i = 0; i < bindingSnapshot.Length; i++)
        {
            bindingSnapshot.GetKey(i, bindingKey, sizeof(bindingKey));

            if (!kv.JumpToKey(bindingKey, true))
                continue;

            kv.SetNum("bind", 1);
            kv.GoBack();
        }

        delete bindingSnapshot;
        kv.GoBack();
    }

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

void ToggleArrayListString(ArrayList list, const char[] value)
{
    if (list == null)
        return;

    char buffer[256];

    for (int i = 0; i < list.Length; i++)
    {
        list.GetString(i, buffer, sizeof(buffer));

        if (StrEqual(buffer, value, false))
        {
            list.Erase(i);
            return;
        }
    }

    list.PushString(value);
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

void ClearVpkBindings()
{
    delete g_hVpkBindings;
    g_hVpkBindings = null;
}

void ClearClientBindingSelection(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    delete g_hBindingContentSelection[client];
    g_hBindingContentSelection[client] = null;

    delete g_hBindingMapSelection[client];
    g_hBindingMapSelection[client]     = null;

    g_sPendingDeleteBinding[client][0] = '\0';
}

void EnsureClientBindingSelection(int client)
{
    if (g_hBindingContentSelection[client] == null)
        g_hBindingContentSelection[client] = new ArrayList(ByteCountToCells(256));

    if (g_hBindingMapSelection[client] == null)
        g_hBindingMapSelection[client] = new ArrayList(ByteCountToCells(256));
}

bool DecodeVpkRuleStorageKey(const char[] key, char[] output, int maxlen)
{
    output[0] = '\0';

    if (!IsVpkRuleStorageKey(key))
        return false;

    int outPos = 0;
    int len    = strlen(key);

    for (int i = 4; i + 1 < len && outPos + 1 < maxlen; i += 2)
    {
        int high = HexDigitValue(key[i]);
        int low  = HexDigitValue(key[i + 1]);

        if (high < 0 || low < 0)
            return false;

        output[outPos++] = view_as<char>((high << 4) | low);
    }

    output[outPos] = '\0';
    return true;
}

void BuildVpkBindingStorageKey(const char[] contentVpk, const char[] mapVpk, char[] buffer, int maxlen)
{
    char contentKey[VPK_RULE_KEY_MAX];
    char mapKey[VPK_RULE_KEY_MAX];

    BuildVpkRuleStorageKey(contentVpk, contentKey, sizeof(contentKey));
    BuildVpkRuleStorageKey(mapVpk, mapKey, sizeof(mapKey));

    FormatEx(buffer, maxlen, "bind_%s__%s", contentKey, mapKey);
}

bool IsVpkBindingStorageKey(const char[] key)
{
    if (strncmp(key, "bind_", 5, false) != 0)
        return false;

    int separator = StrContains(key, "__", false);
    if (separator <= 5)
        return false;

    char contentKey[VPK_RULE_KEY_MAX];
    char mapKey[VPK_RULE_KEY_MAX];

    int  contentLen = separator - 5;
    if (contentLen <= 0 || contentLen >= sizeof(contentKey))
        return false;

    for (int i = 0; i < contentLen; i++)
        contentKey[i] = key[5 + i];

    contentKey[contentLen] = '\0';

    strcopy(mapKey, sizeof(mapKey), key[separator + 2]);

    return IsVpkRuleStorageKey(contentKey) && IsVpkRuleStorageKey(mapKey);
}

bool ParseVpkBindingStorageKey(const char[] bindingKey, char[] contentVpk, int contentMaxlen, char[] mapVpk, int mapMaxlen)
{
    contentVpk[0] = '\0';
    mapVpk[0]     = '\0';

    if (!IsVpkBindingStorageKey(bindingKey))
        return false;

    int  separator = StrContains(bindingKey, "__", false);

    char contentKey[VPK_RULE_KEY_MAX];
    char mapKey[VPK_RULE_KEY_MAX];

    int  contentLen = separator - 5;

    for (int i = 0; i < contentLen; i++)
        contentKey[i] = bindingKey[5 + i];

    contentKey[contentLen] = '\0';

    strcopy(mapKey, sizeof(mapKey), bindingKey[separator + 2]);

    if (!DecodeVpkRuleStorageKey(contentKey, contentVpk, contentMaxlen))
        return false;

    if (!DecodeVpkRuleStorageKey(mapKey, mapVpk, mapMaxlen))
        return false;

    return true;
}

bool SetVpkBinding(const char[] contentVpk, const char[] mapVpk, bool enabled)
{
    if (g_hVpkBindings == null)
        g_hVpkBindings = new StringMap();

    char bindingKey[VPK_BINDING_KEY_MAX];
    BuildVpkBindingStorageKey(contentVpk, mapVpk, bindingKey, sizeof(bindingKey));

    if (enabled)
        g_hVpkBindings.SetValue(bindingKey, 1);
    else
        g_hVpkBindings.Remove(bindingKey);

    return SaveVpkRulesCache();
}

bool IsVpkBoundToMap(const char[] contentVpk, const char[] mapVpk)
{
    if (g_hVpkBindings == null)
        return false;

    char bindingKey[VPK_BINDING_KEY_MAX];
    BuildVpkBindingStorageKey(contentVpk, mapVpk, bindingKey, sizeof(bindingKey));

    int value;
    return g_hVpkBindings.GetValue(bindingKey, value);
}

bool IsVpkBoundToAnyMapList(const char[] contentVpk, ArrayList mapList)
{
    if (g_hVpkBindings == null || mapList == null)
        return false;

    char mapVpk[256];

    for (int i = 0; i < mapList.Length; i++)
    {
        mapList.GetString(i, mapVpk, sizeof(mapVpk));

        if (IsVpkBoundToMap(contentVpk, mapVpk))
            return true;
    }

    return false;
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

bool IsValidMenuClient(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
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
    delete gd.CreateDetourOrFail("CMatchExtL4D::ParseMissionFromFile", true, DTR_PreParseMissionFromFile, DTR_ParseMissionFromFile_Post);
    delete gd.CreateDetourOrFail("CDirectorChallengeMode::InitScriptsNonVirtual", true, DTR_PreCDirectorChallengeMode_InitScriptsNonVirtual);
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
            hFile.WriteLine("			\"CBaseServer::UpdateGameData\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"library\" \"engine\"");
            hFile.WriteLine("				\"linux\"		\"@_ZN11CBaseServer14UpdateGameDataEv\"");
            hFile.WriteLine("				\"windows\"	\"\\x55\\x8B\\xEC\\x81\\xEC\\x64\\x01\\x00\\x00\\xA1\\x2A\\x2A\\x2A\\x2A\\x33\\xC5\\x89\\x45\\xFC\\x53\"");
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
            hFile.WriteLine("			\"CBaseServer::UpdateGameData\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"signature\" \"CBaseServer::UpdateGameData\"");
            hFile.WriteLine("				\"callconv\" \"thiscall\"");
            hFile.WriteLine("				\"return\" \"void\"");
            hFile.WriteLine("				\"this\" \"ignore\"");
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
