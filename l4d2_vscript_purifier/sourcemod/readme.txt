# Left 4 Dead 2 专用服务器 VScript 防污染机制 #
# Left 4 Dead 2 Dedicated Server VScript Anti-Contamination Mechanism#
 
## 功能 / Function 
*   **核心目标：** 防止在专用服务器上加载地图时，出现 **第三方地图脚本污染** 问题。
*   **Core Objective:** Prevent **third-party map script contamination** issues when loading maps on dedicated servers.
*   **问题描述：** 当游玩地图 A 时，错误地加载并执行了地图 B 的脚本。这通常源于不同地图作者在脚本编写能力和规范遵循上的差异。
*   **Problem Description:** When playing Map A, scripts intended for Map B are erroneously loaded and executed. This typically stems from varying levels of scripting proficiency and adherence to standards among map authors.
*   **常见污染脚本示例：** `director_base_addon.nut`,  `scriptedmode_addon.nut`,  `mapspawn_addon.nut`,  `coop.nut`,  `realism.nut`  以及许多其他设计为全局加载的脚本。
*   **Common Contamination Script Examples:** `director_base_addon.nut`,  `scriptedmode_addon.nut`,  `mapspawn_addon.nut`,  `coop.nut`,  `realism.nut`,  and many other scripts designed to load globally.
 
## 注意事项 / Important Notes
*   **识别受控脚本：** 只有那些与地图的 `mission` 文件（如 `a1_intro_mall.nut` ）**打包在同一个 VPK 文件内** 的脚本文件，才会被本机制识别为 **地图脚本** 并进行加载限制。
*   **Identifying Controlled Scripts:** Only script files that are **packaged within the same VPK file** as the map's `mission` file (e.g., `a1_intro_mall.nut`)  are identified as **map scripts** and subjected to loading restrictions by this mechanism.
*   **豁免脚本：** 位于 VPK 文件 **之外** 的脚本（例如直接放置在 `scripts/vscripts/` 目录下的脚本）会被视为 **普通的脚本类型模组 (Mod)**，本机制 **不会阻止** 其加载。
*   **Exempted Scripts:** Scripts located **outside** of VPK files (e.g., placed directly in the `scripts/vscripts/` directory) are treated as **regular script-type mods**, and their loading is **NOT prevented** by this mechanism.
 
## 白名单机制 / Whitelist Mechanism 
*   **自动生成：** 插件在 **首次成功运行后**，会自动生成两个白名单配置文件。
*   **Automatic Generation:** The plugin automatically generates two whitelist configuration files upon **successful first run**.
1.  **模式脚本白名单：**
    *   **文件路径：** `cfg/configs/l4d2_vscript_mode_whitelist.cfg` 
    *   **作用：** 此白名单中列出的 **游戏模式脚本**（例如 `coop`, `versus`, `survival` 等）将被 **放行** 加载。
    *   **Mode Script Whitelist:**
        *   **File Path:** `cfg/configs/l4d2_vscript_mode_whitelist.cfg` 
        *   **Purpose:** **Game mode scripts** listed in this whitelist (e.g., `coop`, `versus`, `survival`) will be **allowed** to load.
2.  **VPK 文件白名单：**
    *   **文件路径：** `cfg/configs/l4d2_vscript_vpk_whitelist.cfg` 
    *   **作用：** 此白名单中列出的 **VPK 文件** 内包含的所有脚本，都将被 **放行** 加载。
    *   **VPK File Whitelist:**
        *   **File Path:** `cfg/configs/l4d2_vscript_vpk_whitelist.cfg` 
        *   **Purpose:** All scripts contained within the **VPK files** listed in this whitelist will be **allowed** to load.
