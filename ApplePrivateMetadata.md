# Apple 私有元数据（识别与排除）

目的
- 详细梳理 Apple 私有扩展字段在 JPEG/HEIC 中的常见位置与含义，给出在转换流程中安全排除这些信息的策略与示例命令，供后续自动化实现使用。

要点速览
- Apple 私有信息常见于三个位置：EXIF MakerNote（bplist 二进制）、XMP 命名空间（例如 `XMP-HDRGainMap`、`XMP-apdi` 等）、以及部分 ICC/厂商字段（`ProfileCreator` 等）。
- 隐私/兼容性风险：`Apple:PhotoIdentifier` / `ContentIdentifier` 等可能泄露设备/照片唯一 ID；MakerNote 中的 bplist 包含大量设备/拍摄细节；保留这些会导致跨平台行为不一致或信息泄露。
- 推荐做法：在转换到 Google 风格 XMP（`XMP-hdrgm`/`XMP-GContainer`）时，先在副本上移除 Apple 私有字段，仅保留标准 EXIF/XMP/APP2（特别是保留 MPF/MPImage trailer），并保存 `exiftool -v3` 转储以便追踪。

一、Apple 私有元数据的常见位置与字段

- EXIF MakerNote（经常呈现为 `Apple:` tag group）
  - 说明：MakerNote 是厂商私有的 EXIF 扩展，Apple 的 MakerNote 常以 bplist（二进制 plist）形式保存复杂结构。
  - 常见条目（在本项目样本中多次出现）：
    - `Apple:HDRGain`、`Apple:HDRHeadroom` — Apple 的 HDR/增益参数（标量/有理数）。
    - `Apple:PhotoIdentifier`、`Apple:ContentIdentifier` — UUID / 标识符（可能关联 iCloud/Photos）。
    - `Apple:LivePhotoVideoIndex`、`Apple:ImageCaptureType`、`Apple:PhotosAppFeatureFlags` — Photos 应用/LivePhoto 相关标记。
    - `Apple:MakerNoteVersion`、`Apple:RunTime*`、`Apple:AF*`、`Apple:FocusPosition`、`Apple:ColorTemperature` 等丰富的相机/拍摄信息。
  - 风险与备注：MakerNote 内容格式厂商私有，跨平台解析有限，可能携带敏感/可追踪数据。

- XMP 命名空间（可由 exiftool 显示为 `XMP-HDRGainMap:`、`XMP-apdi:` 等）
  - `XMP-HDRGainMap`（Apple 命名空间，URI 类似 `http://ns.apple.com/HDRGainMap/1.0/`）
    - 常见 tag：`HDRGainMapVersion`、`HDRGain`、`HDRGainCurve*` 等。
    - 用途：Apple 在 XMP 层表示 HDR 增益图（与 MakerNote 及 HEIC 中的 HDRGainMap 相关）。
  - `XMP-apdi`（在样本中看到 `NativeFormat`/`StoredFormat`，例如 `L008`）
    - 说明：Apple/相机内部的图像存储/原始格式标注，非标准跨平台字段。

- 其他厂商/ICC 字段
  - ICC Profile 中的 `ProfileCreator`、`ProfileCopyright`、`PrimaryPlatform` 等可能标注为 `Apple Computer Inc.`，这些不是私有敏感字段，但在文档中可记录并根据需要保留或替换。

二、检测 Apple 私有字段（示例命令）

- 列出文件中 Apple 相关的 EXIF/XMP 字段（PowerShell 安全示例）：

```powershell
# 列出 Apple EXIF MakerNote 映射出的字段
exiftool -G1 -a -s "R:/IMG_6703.JPG" | Select-String "\[Apple\]" -Context 0,0

# 或者直接用 exiftool 的 tag-wildcard（多数环境可用）
exiftool -G1 -a -s -Apple:* "R:/IMG_6703.JPG"

# 列出 XMP-HDRGainMap / XMP-apdi
exiftool -G1 -a -s -XMP-HDRGainMap:* -XMP-apdi:* "R:/IMG_6703.JPG"

# 把完整 JSON 导出并用脚本过滤键名（便于自动化）：
exiftool -json -G1 "R:/IMG_6703.JPG" > "D:/MultiMediaTools/tmp/IMG_6703.metadata.json"
# 然后用脚本查找以 "Apple:" 或 "XMP-HDRGainMap:" 开头的键
```

三、删除 / 排除策略（分级建议）

建议先在副本上操作；所有示例都假设你已在 `D:/MultiMediaTools/variants/` 创建了待处理副本。

- 级别 A — 最小化（仅移除 Apple HDR 相关与显式标识符，保留其它 MakerNote 内容）
  - 说明：移除用户追踪或与 HDR 冲突的关键字段即可；适合保留部分苹果诊断信息的场景。
  - 示例命令（PowerShell-safe）：
    ```powershell
    exiftool -overwrite_original \
      "-Apple:HDRGain=" \
      "-Apple:HDRHeadroom=" \
      "-Apple:PhotoIdentifier=" \
      "-Apple:ContentIdentifier=" \
      "-XMP-HDRGainMap:All=" \
      "-XMP-apdi:All=" \
      "D:/MultiMediaTools/variants/neatuhdr_google_xmp_addXMPGain.jpg"
    ```

- 级别 B — 推荐（移除所有 Apple 命名空间项与 MakerNote）
  - 说明：对外分发或转换为非 Apple 格式时推荐，最大程度避免 Apple 私有字段残留。
  - 示例命令：
    ```powershell
    exiftool -overwrite_original \
      "-XMP-HDRGainMap:All=" \
      "-XMP-apdi:All=" \
      "-Apple:All=" \
      "-EXIF:MakerNote=" \
      "D:/MultiMediaTools/variants/neatuhdr_google_xmp_addXMPGain.jpg"
    ```
  - 备注：部分 exiftool 版本或 tag-group 可能不支持 `Group:All=` 语法（极少见），因此更稳健的方法是先枚举再删除（见下伪代码）。

- 级别 C — 激进（删除所有非标准厂商扩展）
  - 说明：对隐私要求极高或要把文件送到严格审计/外部发布场景，可删除所有 MakerNote 和厂商命名空间，保留标准 EXIF/XMP/APP2/MPF。示例命令类似 B，但可加上 `-ICC_Profile:All=`（若需移除 ICC）。

四、稳健实现（伪代码 / 建议实现流程）

伪代码：安全地枚举并清除 Apple 私有键（推荐实现，避免对 exiftool 的 `Group:All=` 依赖）

```text
FUNCTION strip_apple_private_tags(src_path, dst_path):
  # 1) 复制源为待处理副本
  copy_file(src_path, dst_path)

  # 2) 用 exiftool 导出 JSON 元数据并解析 keys
  meta_json = run("exiftool -json -G1 " + quote(dst_path))
  keys = parse_json(meta_json)[0].keys()

  # 3) 筛选需要删除的键（以 Apple: / XMP-HDRGainMap: / XMP-apdi: 开头）
  remove_keys = keys.filter(k -> k.startsWith("Apple:") or k.startsWith("XMP-HDRGainMap:") or k.startsWith("XMP-apdi:"))

  # 4) 构造 exiftool 删除参数：-Key1= -Key2= ...（注意在 PowerShell 中适当引用）
  args = remove_keys.map(k -> "-" + k + "=")

  # 5) 调用 exiftool 删除（使用 -overwrite_original 并保留 v3 dump 以便审计）
  run("exiftool -overwrite_original " + args.join(" ") + " " + quote(dst_path))

  # 6) 导出并保存验证用的 exiftool -v3 转储
  run("exiftool -v3 " + quote(dst_path) + " > " + quote(dst_path + ".exif_v3.txt"))

  # 7) 验证：再次检查 dst_path 中不再含 Apple: / XMP-HDRGainMap: / XMP-apdi: 键
  return success_if_no_keys_found
```

五、验证/测试（必须）

- 每次批量处理后都要保存并提交：
  - `dst.jpg.exif_v3.txt`（`exiftool -v3` 输出）和 `dst.jpg.json`（`exiftool -json -G1`），以便回溯与差异对比。
- 自动化测试示例（PowerShell 风格）：
  - 对目录中的每个文件运行 `exiftool -G1 -json file` 并断言 JSON 中没有以 `Apple:` / `XMP-HDRGainMap:` / `XMP-apdi:` 开头的键。若有，列出并失败。

六、在转换流水线中的位置建议

- 建议点：在 `hdr2uhdr` / `ultrahdr_app` 的元数据复制/写入步骤之后，且在写入 Google 风格 XMP (`XMP-hdrgm` / `XMP-GContainer`) 之前执行清理。顺序举例：
  1. ultrahdr_app 生成 JPEG payload + MPF trailer（保留 MPImage2）。
 2. 从源文件 `TagsFromFile`（或手动选择）复制所需标准 EXIF/XMP 到副本。
 3. 运行 `strip_apple_private_tags()` 清理 Apple 私有字段（在副本上）。
 4. 写入 `XMP-hdrgm` / `XMP-GContainer`（保留 MPF/MPImage2 长度一致）。

七、注意事项与边界情况

- MakerNote 中的 bplist 可能包含二进制子结构，exiftool 的 JSON 导出会把其呈现为 `bplist00...` 字符串或 `Apple_0x00xx` 条目；删除时以键名为准，不要试图直接“编辑” bplist 内容（会复杂且容易出错）。
- 如需保留某些 Apple 字段（用于内部调试），请先导出并存档到 `D:/MultiMediaTools/apple_debug/<file>.json`，再在正式变体中删除。
- 如果你的目标是最大兼容性（Android/Google），请优先保留或添加 `XMP-hdrgm` / `XMP-GContainer`，并删除 Apple 私有项以避免歧义。

八、项目中现有参考与示例

- `D:/MultiMediaTools/all_meta.json` — 含有样本集合，其中包含大量 `Apple:` 字段（可作为检测/筛选参考）。
- `D:/MultiMediaTools/variants/neatuhdr_google_xmp_addXMPGain.jpg` — 已实现 GContainer 的变体（示例：无 Apple 私有字段）。
- `D:/MultiMediaTools/variants/neatuhdr_google_xmp_b64gain.jpg` — base64 XMP 变体（同样可作为测试对象）。

九、我可以帮你做的事（选项）

1. 把 `strip_apple_private_tags` 实现为 `PowerShell` 或 `bash` 脚本并把它加入 `D:/MultiMediaTools/tools/`（含日志与回滚备份）。
2. 在现有转换脚本（`hdr2uhdr.ps1` / `create_xmp_gainmap_variants.ps1`）中集成清理步骤并在每次变体生成后自动验证。 
3. 把当前仓库中所有样本批量扫描一遍，生成 `apple_private_report.csv`，列出含有 Apple 私有键的文件与键名（便于决策）。

请选择你想要我接下来的操作（回复数字 1 / 2 / 3，或给出其他指示）。
