#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>

#define GAMEDATA         "l4d2_vscript_purifier"
#define GAMEDATA_VERSION 49

methodmap GameDataWrapper < GameData
{

public     GameDataWrapper(const char[] file)
    {
        GameData gd = new GameData(file);
        if (!gd) SetFailState("[GameData] Missing gamedata of file \"%s\".", file);
        return view_as<GameDataWrapper>(gd);
    }

public     DynamicDetour CreateDetourOrFail(const char[] name,
                                     bool          bNow     = true,
                                     DHookCallback preHook  = INVALID_FUNCTION,
                                     DHookCallback postHook = INVALID_FUNCTION)
    {
        DynamicDetour hSetup = DynamicDetour.FromConf(this, name);

        if (!hSetup)
            SetFailState("[Detour] Missing detour setup section \"%s\".", name);

        if (bNow)
        {
            if (preHook != INVALID_FUNCTION && !hSetup.Enable(Hook_Pre, preHook))
                SetFailState("[Detour] Failed to pre-detour of section \"%s\".", name);

            if (postHook != INVALID_FUNCTION && !hSetup.Enable(Hook_Post, postHook))
                SetFailState("[Detour] Failed to post-detour of section \"%s\".", name);
        }

        return hSetup;
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

enum struct SelfMapInfo
{
    char VpkName[256];
    char CurrentMapName[128];
    char LogFilePath[128];
    char GameMode[64];
}

SelfMapInfo
    g_MapInfo;

DynamicDetour
    V_snprintf;

ArrayList
    g_aContentList,
    g_aCvarVscriptChanged,
    g_aGlobalVpkNoAllow,
    g_aModeWhitelist,
    g_aVpkWhitelist;

Address
    g_pVecAddonMetadata;

Handle
    g_hSDK_VScriptRunForAllAddons,
    fileHandle = null;

ConVar
    mp_gamemode,
    g_hCvar_Switch,
    g_hCvar_Restore,
    g_hCvar_ModeWhiteList,
    g_hCvar_VpkWhiteList;

bool
    g_bProcessModeVscript,
    g_bLinuxOS,
    g_bMissionReload,
    g_bFoundVpk;

int
    g_iAllowModeScript,
    g_icvSwitch,
    g_icvRestore;

char
    g_sModeWhitelistPath[PLATFORM_MAX_PATH],
    g_sVpkWhitelistPath[PLATFORM_MAX_PATH];

public Plugin myinfo =
{
    name        = "l4d2_vscript_purifier",
    author      = "洛琪, Forgetest",
    description = "防止地图脚本污染",
    version     = "1.2",
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
    mp_gamemode           = FindConVar("mp_gamemode");
    g_hCvar_Switch        = CreateConVar("l4d2_vscript_purifier", "2", "是否阻止非法脚本造成脚本污染,0不阻止, 1阻止, 2阻止并控制台打印信息, 3阻止并且将阻止情况记录到日志里,\\n[注意,地图脚本必须和地图mission文件放在同一个vpk内，才会被识别为地图脚本，否则会识别为脚本类MOD]", FCVAR_NOTIFY, true, 0.0, true, 3.0);
    g_hCvar_Restore       = CreateConVar("l4d2_vscript_cvarRestore", "1", "是否在过关时自动还原被脚本修改的cvar值,1是，0否.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hCvar_ModeWhiteList = CreateConVar("l4d2_vscript_modewhiteList", "1", "是否读取模式白名单内容?白名单位于configs文件夹下.[例如,mutation4在白名单内，则所有此模式脚本都会放行.]", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_hCvar_VpkWhiteList  = CreateConVar("l4d2_vscript_modewhiteList", "1", "是否读取Vpk白名单内容?白名单位于configs文件夹下.[此Vpk名称下的全部脚本放行.]", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    mp_gamemode.AddChangeHook(OnCvarChanged);
    g_hCvar_Switch.AddChangeHook(OnCvarChanged);
    g_hCvar_Restore.AddChangeHook(OnCvarChanged);
    AutoExecConfig(true, "l4d2_vscript_purifier");
    InItGameData();

    char logFile[100];
    Format(logFile, sizeof(logFile), "/logs/vscript_purifier.log");
    BuildPath(Path_SM, g_MapInfo.LogFilePath, PLATFORM_MAX_PATH, logFile);

    InItWhiteListFunc();
    UpdateCvars();
    ExecConfigsEarly();

    HookEvent("round_start_pre_entity", Event_PreRoundStart, EventHookMode_PostNoCopy);
}

void InItWhiteListFunc()
{
    BuildPath(Path_SM, g_sModeWhitelistPath, sizeof(g_sModeWhitelistPath), "configs/l4d2_vscript_mode_whitelist.cfg");
    BuildPath(Path_SM, g_sVpkWhitelistPath, sizeof(g_sVpkWhitelistPath), "configs/l4d2_vscript_vpk_whitelist.cfg");
    delete g_aModeWhitelist;
    delete g_aVpkWhitelist;
    g_aModeWhitelist = new ArrayList(ByteCountToCells(64));
    g_aVpkWhitelist  = new ArrayList(ByteCountToCells(64));
    CheckAndCreateWhitelistFile(g_sModeWhitelistPath, "ModeWhitelist");
    CheckAndCreateWhitelistFile(g_sVpkWhitelistPath, "VpkWhitelist");
    if (g_hCvar_ModeWhiteList.BoolValue)
        ReadWhitelistFile(g_sModeWhitelistPath, g_aModeWhitelist);
    if (g_hCvar_VpkWhiteList.BoolValue)
        ReadWhitelistFile(g_sVpkWhitelistPath, g_aVpkWhitelist);
}

void CheckAndCreateWhitelistFile(const char[] path, const char[] section)
{
    if (FileExists(path))
        return;

    File file = OpenFile(path, "w", false);
    if (file == null)
        return;

    if (StrEqual(section, "ModeWhitelist"))
        file.WriteLine("// 将需要放行的模式名称写入空白键值处，如coop");
    else
        file.WriteLine("// 将需要放行的vpk名称写入空白键值处，如example.vpk");

    file.WriteLine("\"%s\"", section);
    file.WriteLine("{");
    for (int i = 1; i <= 64; i++)
    {
        file.WriteLine("\t\"entry%d\" \"\"", i);
    }
    file.WriteLine("}");
    delete file;
}

void ReadWhitelistFile(const char[] path, ArrayList list)
{
    list.Clear();

    KeyValues kv = new KeyValues("");
    if (!kv.ImportFromFile(path))
    {
        delete kv;
        return;
    }

    kv.GotoFirstSubKey(false);

    char value[64];
    do
    {
        kv.GetString(NULL_STRING, value, sizeof(value));
        if (strlen(value) > 0)
        {
            if (list.FindString(value) == -1)
                list.PushString(value);
        }
    }
    while (kv.GotoNextKey(false));
    delete kv;
}

void ExecConfigsEarly()
{
    ServerCommand("exec sourcemod/l4d2_vscript_purifier.cfg");
    ServerExecute();
    UpdateCvars();
}

void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    UpdateCvars();
}

void UpdateCvars()
{
    g_icvSwitch  = g_hCvar_Switch.IntValue;
    g_icvRestore = g_hCvar_Restore.IntValue;
    mp_gamemode.GetString(g_MapInfo.GameMode, sizeof(g_MapInfo.GameMode));
}

public void OnMapInit(const char[] mapName)
{
    delete g_aContentList;
    delete g_aGlobalVpkNoAllow;
    g_aContentList      = new ArrayList(ByteCountToCells(256));
    g_aGlobalVpkNoAllow = new ArrayList(ByteCountToCells(256));
    FormatEx(g_MapInfo.CurrentMapName, sizeof(g_MapInfo.CurrentMapName), mapName);

    g_bFoundVpk = false;
    ServerCommand("mission_reload");
    ServerExecute();

    char buffer[256];
    g_aGlobalVpkNoAllow.GetString(0, buffer, sizeof(buffer));
    AddonMetadata meta;
    Address       pMemory = LoadFromAddress(g_pVecAddonMetadata, NumberType_Int32);
    int           size    = LoadFromAddress(g_pVecAddonMetadata + view_as<Address>(12), NumberType_Int32);
    for (int i = 0; i < size; ++i)
    {
        ReadMemoryString(pMemory + view_as<Address>(i * 4 * sizeof(meta) + 4 * AddonMetadata::file), meta.file, sizeof(meta.file));
        ReadMemoryString(pMemory + view_as<Address>(i * 4 * sizeof(meta) + 4 * AddonMetadata::name), meta.name, sizeof(meta.name));
        meta.type    = LoadFromAddress(pMemory + view_as<Address>(i * 4 * sizeof(meta) + 4 * AddonMetadata::type), NumberType_Int32);
        meta.unknown = LoadFromAddress(pMemory + view_as<Address>(i * 4 * sizeof(meta) + 4 * AddonMetadata::unknown), NumberType_Int32);
        char buffers[256];
        strcopy(buffers, sizeof(buffers), meta.file);

        char parts[16][256];
        int  count = ExplodeString(buffers, "/", parts, sizeof(parts), sizeof(parts[]));
        for (int j = count - 1; j >= 0; j--)
        {
            if (StrEqual(parts[j], ""))
                continue;

            int len = strlen(parts[j]);
            if (len < 4)
                continue;

            char suffix[5];
            strcopy(suffix, sizeof(suffix), parts[j][len - 4]);

            if (StrEqual(suffix, ".vpk", false))
            {
                if (meta.type == Metadata_Mission)
                {
                    if ((StrContains(buffer, meta.name) == -1))
                        g_aGlobalVpkNoAllow.PushString(parts[j]);
                    else
                        strcopy(g_MapInfo.VpkName, sizeof(g_MapInfo.VpkName), parts[j]);
                }
                else
                    g_aContentList.PushString(parts[j]);
                break;
            }
            break;
        }
    }
    g_aGlobalVpkNoAllow.Erase(0);
    UnhookEvent("round_start_pre_entity", Event_PreRoundStart, EventHookMode_PostNoCopy);
    Call_VeryEarly();
}

public void OnMapStart()
{
    HookEvent("round_start_pre_entity", Event_PreRoundStart, EventHookMode_PostNoCopy);
}

void Event_PreRoundStart(Event event, const char[] name, bool dontBroadcast)
{
    Call_VeryEarly();
}

void Call_VeryEarly()
{
    ConvarRestoreDftault();
    delete g_aCvarVscriptChanged;
    g_aCvarVscriptChanged = new ArrayList(ByteCountToCells(64));
    g_iAllowModeScript    = 0;
    V_snprintf.Enable(Hook_Pre, DTR_PreV_snprintf);
    g_bProcessModeVscript = true;
    SDKCall(g_hSDK_VScriptRunForAllAddons, g_MapInfo.GameMode, 0, 1);
    g_bProcessModeVscript = false;
    V_snprintf.Disable(Hook_Pre, DTR_PreV_snprintf);
}

void ConvarRestoreDftault()
{
    if (g_icvRestore != 1 || g_aCvarVscriptChanged == null) return;

    char   buffer[64];
    ConVar g_CvTemp;
    for (int i = 0; i < g_aCvarVscriptChanged.Length; i++)
    {
        g_CvTemp = null;
        g_aCvarVscriptChanged.GetString(i, buffer, sizeof(buffer));
        g_CvTemp = FindConVar(buffer);
        if (g_CvTemp != null)
            g_CvTemp.RestoreDefault(true);
    }
}

void ReadMemoryString(Address addr, char[] buffer, int size)
{
    int max = size - 1;

    int i   = 0;
    for (; i < max; i++)
        if ((buffer[i] = view_as<char>(LoadFromAddress(addr + view_as<Address>(i), NumberType_Int8))) == '\0')
            return;

    buffer[i] = '\0';
}

MRESReturn DTR_PreParseMissionFromFile(Address pMatchExtL4D, DHookReturn hReturn, DHookParam hParams)
{
    if (!g_bFoundVpk)
    {
        g_bMissionReload = true;
        char buffer[256];
        DHookGetParamString(hParams, 1, buffer, sizeof(buffer));
        if (StrContains(buffer, "missions", false) != -1)
        {
            if (g_aGlobalVpkNoAllow.Length != 0)
                g_aGlobalVpkNoAllow.Erase(0);
            g_aGlobalVpkNoAllow.PushString(buffer);
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
    if (!g_bMissionReload) return MRES_Ignored;

    if (!DHookIsNullParam(hParams, 1))
    {
        char filename1[8];
        DHookGetParamString(hParams, 1, filename1, sizeof(filename1));
        if (StrEqual(filename1, "map", false))
        {
            char filename2[256];
            DHookGetReturnString(hReturn, filename2, sizeof(filename2));
            if (StrEqual(g_MapInfo.CurrentMapName, filename2, false))
            {
                g_bFoundVpk = true;
            }
        }
    }
    return MRES_Ignored;
}

MRESReturn DTR_PreVScriptServerRunScript(DHookReturn hReturn, DHookParam hParams)
{
    if (g_icvSwitch < 1) return MRES_Ignored;

    char filename[256], buffer[96];
    DHookGetParamString(hParams, 1, filename, sizeof(filename));

    if (g_bProcessModeVscript)
    {
        if (StrContains(filename, ".vpk", false) == -1)
            g_iAllowModeScript = 1;

        if (StrContains(filename, g_MapInfo.VpkName, false) != -1)
            g_iAllowModeScript = 2;

        for (int i = 0; g_aContentList != null && i < g_aContentList.Length; i++)
        {
            g_aContentList.GetString(i, buffer, sizeof(buffer));
            if (StrContains(filename, buffer, false) != -1)
            {
                g_iAllowModeScript = 3;
                break;
            }
        }

        hReturn.Value = 1;
        return MRES_Supercede;
    }

    bool bAllow = true;
    for (int j = 0; g_aGlobalVpkNoAllow != null && j < g_aGlobalVpkNoAllow.Length; j++)
    {
        g_aGlobalVpkNoAllow.GetString(j, buffer, sizeof(buffer));
        if (StrContains(filename, buffer, false) != -1)
        {
            bAllow = false;
            if (g_aVpkWhitelist.FindString(buffer) != -1)
                bAllow = true;
            break;
        }
    }

    if (StrEqual(filename, g_MapInfo.GameMode, false))
    {
        if (g_iAllowModeScript == 0)
            bAllow = false;
        if (g_aModeWhitelist.FindString(g_MapInfo.GameMode) != -1)
        {
            bAllow             = true;
            g_iAllowModeScript = 4;
        }
    }

    if (g_icvSwitch >= 2)
    {
        char prefix[64], name[192], reason[96];
        if (bAllow)
            FormatEx(prefix, sizeof(prefix), "[L4D2 Vscript Purifier] Allowed:");
        else
            FormatEx(prefix, sizeof(prefix), "[L4D2 Vscript Purifier] Blocked:");

        if (StrEqual(filename, g_MapInfo.GameMode, false))
        {
            FormatEx(name, sizeof(name), "scripts/vscripts/%s.nut", filename);
            switch (g_iAllowModeScript)
            {
                case 0: FormatEx(reason, sizeof(reason), "reason: current Vpk file dones't have this scripts file");
                case 1: FormatEx(reason, sizeof(reason), "reason: file exist in left4dead2/scripts/vscripts/");
                case 2: FormatEx(reason, sizeof(reason), "reason: file exist in this Map Vpk File");
                case 3: FormatEx(reason, sizeof(reason), "reason: file exist in other Content Vpk File");
                case 4: FormatEx(reason, sizeof(reason), "reason: white list allowed.");
            }
            PrintToServer("%s %s %s", prefix, name, reason);
        }

        if ((StrContains(filename, ".vpk", false) != -1))
        {
            strcopy(name, sizeof(name), filename);
            FormatEx(reason, sizeof(reason), " ");
            if (!bAllow)
                FormatEx(reason, sizeof(reason), "reason: current Vpk file dones't have this scripts file");
            PrintToServer("%s %s %s", prefix, name, reason);
        }

        if (g_icvSwitch == 3 && !bAllow)
        {
            char message[256];
            FormatEx(message, sizeof(message), "[Current Map]: [%s] %s %s %s", g_MapInfo.CurrentMapName, prefix, name, reason);
            fileHandle = OpenFile(g_MapInfo.LogFilePath, "a");
            WriteFileLine(fileHandle, message);
            CloseHandle(fileHandle);
        }
    }

    if (bAllow) return MRES_Ignored;

    hReturn.Value = 1;
    return MRES_Supercede;
}

MRESReturn DTR_PreCScriptConvarAccessor_SetValue(DHookReturn hReturn, DHookParam hParams)
{
    char CvarName[64];
    DHookGetParamString(hParams, 1, CvarName, sizeof(CvarName));
    if (g_aCvarVscriptChanged == null)
    {
        delete g_aCvarVscriptChanged;
        g_aCvarVscriptChanged = new ArrayList(ByteCountToCells(64));
    }
    g_aCvarVscriptChanged.PushString(CvarName);
    return MRES_Ignored;
}

MRESReturn DTR_PreV_snprintf(DHookReturn hReturn, DHookParam hParams)
{
    if (!g_bProcessModeVscript) return MRES_Ignored;

    char Rest[128];
    FormatEx(Rest, sizeof(Rest), "scripts/vscripts/%s.nut", g_MapInfo.GameMode);
    DHookSetParamString(hParams, 3, Rest);
    return MRES_ChangedHandled;
}

void InItGameData()
{
    CheckGameDataFile();

    Address         g_pVscriptMsgFunc;
    GameDataWrapper gd  = new GameDataWrapper(GAMEDATA);
    g_bLinuxOS          = gd.GetOffset("OS") == 1;
    g_pVscriptMsgFunc   = gd.GetAddress("msg_VScriptServerRunScriptForAllAddons");
    g_pVecAddonMetadata = gd.GetAddress("s_vecAddonMetadata");
    int offset          = g_bLinuxOS ? 232 : 165;
    int bypeLength      = g_bLinuxOS ? 5 : 6;
    int byte            = LoadFromAddress(g_pVscriptMsgFunc + view_as<Address>(offset), NumberType_Int8);
    if ((byte == 0xE8 && g_bLinuxOS) || (byte == 0xFF && !g_bLinuxOS))
    {
        for (int i = 0; i < bypeLength; i++)
            StoreToAddress(g_pVscriptMsgFunc + view_as<Address>(offset + i), 0x90, NumberType_Int8);
    }
    else if (byte != 0x90)
        PrintToServer("Falied to Patch msg_VScriptServerRunScriptForAllAddons");

    StartPrepSDKCall(SDKCall_Static);
    if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "VScriptServerRunScriptForAllAddons"))
        SetFailState("Failed to find signature: \"VScriptServerRunScriptForAllAddons\"");
    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_hSDK_VScriptRunForAllAddons = EndPrepSDKCall();

    delete gd.CreateDetourOrFail("KeyValues::GetString", true, _, DTR_KeyValues_GetString_Post);
    delete gd.CreateDetourOrFail("CMatchExtL4D::ParseMissionFromFile", true, DTR_PreParseMissionFromFile, DTR_ParseMissionFromFile_Post);
    delete gd.CreateDetourOrFail("VScriptServerRunScript", true, DTR_PreVScriptServerRunScript);
    delete gd.CreateDetourOrFail("CScriptConvarAccessor::SetValue", true, DTR_PreCScriptConvarAccessor_SetValue);
    V_snprintf = gd.CreateDetourOrFail("V_snprintf", false, DTR_PreV_snprintf);

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
            hFile.WriteLine("			\"VScriptServerRunScript\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"library\" \"server\"");
            hFile.WriteLine("				\"linux\"		\"@_Z22VScriptServerRunScriptPKcP9HSCRIPT__b\"");
            hFile.WriteLine("				\"windows\"	\"\\x55\\x8B\\xEC\\x83\\xEC\\x10\\x83\\x3D\\x2A\\x2A\\x2A\\x2A\\x00\\x75\\x2A\"");
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
            hFile.WriteLine("			\"V_snprintf\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"library\" \"server\"");
            hFile.WriteLine("				\"linux\"		\"@_Z10V_snprintfPciPKcz\"");
            hFile.WriteLine("				\"windows\"	\"\\x55\\x8B\\xEC\\x8B\\x4D\\x10\\x56\\x8B\\x75\\x0C\"");
            hFile.WriteLine("			}");
            hFile.WriteLine("");
            hFile.WriteLine("		}");
            hFile.WriteLine("");
            hFile.WriteLine("		\"Functions\"");
            hFile.WriteLine("		{");
            hFile.WriteLine("			\"VScriptServerRunScript\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"signature\" \"VScriptServerRunScript\"");
            hFile.WriteLine("				\"callconv\" \"cdecl\"");
            hFile.WriteLine("				\"return\" \"int\"");
            hFile.WriteLine("				\"this\" \"ignore\"");
            hFile.WriteLine("				\"arguments\"");
            hFile.WriteLine("				{");
            hFile.WriteLine("					\"a1\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"charptr\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("					\"a2\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"int\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("					\"a3\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"int\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("				}");
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
            hFile.WriteLine("			\"V_snprintf\"");
            hFile.WriteLine("			{");
            hFile.WriteLine("				\"signature\" \"V_snprintf\"");
            hFile.WriteLine("				\"callconv\" \"cdecl\"");
            hFile.WriteLine("				\"return\" \"int\"");
            hFile.WriteLine("				\"this\" \"ignore\"");
            hFile.WriteLine("				\"arguments\"");
            hFile.WriteLine("				{");
            hFile.WriteLine("					\"dest\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"charptr\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("					\"length\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"int\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("					\"src1\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"charptr\"");
            hFile.WriteLine("					}");
            hFile.WriteLine("					\"src2\"");
            hFile.WriteLine("					{");
            hFile.WriteLine("						\"type\" \"charptr\"");
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
