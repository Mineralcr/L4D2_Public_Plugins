Function: 
    Prevent third-party map script contamination on dedicated servers. The script for map B was run on map A. This is usually due to uneven script proficiency among map authors. Common pollution scripts include director_mase-addon, scriptedmode-addon, mapspawn-addon, coop, realism, and many other global loading scripts
Attention: 
  Only script files that are in the same VPK file as the mission file will be considered as map script files for restriction. Otherwise, they will be considered as regular script type mods and will not be prevented from loading.

功能：
  阻止专用服务器上三方地图脚本污染的问题。即在地图A上运行了地图B的脚本。这通常是由于地图作者在脚本水平方面参差不齐导致的。常见的污染脚本有：director_base_addon、scriptedmode_addon、mapspawn_addon、coop、realism 和许多其他的全局加载脚本
﻿
注意事项：
  只有和mission文件在同一个vpk文件下的脚本文件才会被认为是地图脚本文件进行限制，否则会被认为是普通脚本类型mod，不阻止其加载。

白名单：
    插件第一次运行后，会在"configs/l4d2_vscript_mode_whitelist.cfg"下生成模式白名单，白名单上的模式脚本放行；
    会在"configs/l4d2_vscript_vpk_whitelist.cfg"下生成vpk白名单，白名单上的vpk文件内的脚本放行.
