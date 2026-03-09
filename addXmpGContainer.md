# addXmpGContainer 记录

本文档记录在项目中创建两个变体文件的完整流程：

- `neatuhdr_google_xmp_addXMPGain.jpg`（简称 addxmpgain）——在 XMP 层补充 Google 所期望的 hdrgm/GContainer 字段，指向 APP2/MPF 的 MPImage2 payload；通常这是大多数软件识别 GainMap 信息所需的最小改动。
- `neatuhdr_google_xmp_b64gain.jpg`（简称 b64gain）——把 MPImage2 二进制编码为 base64，嵌入到 XMP（`<Google:GainMapImage>`）中，作为更显式的备用表示，供不通过 MPF trailer 读取的解析器使用。

下面按步骤说明如何复现这两个变体、验证要点与常见注意事项。

前提工具
- exiftool 安装并在 PATH 中可用（本文动作在 Windows/PowerShell 环境中测试）。
- PowerShell：注意参数与引号的处理（见下）。

一、准备：确认原始文件并抽取 MPImage2 长度

1. 确认源文件（示例）：`R:\NeatUHDR\neatuhdr.jpg`，先复制为工作变体：

```powershell
Copy-Item 'R:\NeatUHDR\neatuhdr.jpg' -Destination 'D:\MultiMediaTools\variants\neatuhdr_google_xmp.jpg' -Force
```

2. 获取 MPImage2 的长度（这是决定 DirectoryItemLength 的来源）：

```bash
exiftool -G1 -s -MPImage2:MPImageLength "D:/MultiMediaTools/variants/neatuhdr_google_xmp.jpg"
# 输出示例： MPImage2:MPImageLength = 5640605
```

二、创建 addxmpgain（最小 XMP 修改）

目标：在文件的 XMP 中添加 `XMP-hdrgm:Version` 以及 `XMP-GContainer` 的并行数组字段，让解析器能够通过 XMP 指向 APP2/MPF 中已有的 MPImage2 payload。

关键点：不要用显式的索引写法（例如 DirectoryItemMime[1]=...）——在 PowerShell 中会被误解析。使用 append 语法 (`+=`) 添加数组项。

示例命令（把 `5640605` 替换成实际的 MPImage2 长度）：

```bash
exiftool -overwrite_original \
  "-XMP-hdrgm:Version=1.0" \
  "-XMP-GContainer:DirectoryItemMime+=image/jpeg" \
  "-XMP-GContainer:DirectoryItemSemantic+=Primary" \
  "-XMP-GContainer:DirectoryItemSemantic+=GainMap" \
  "-XMP-GContainer:DirectoryItemLength+=0" \
  "-XMP-GContainer:DirectoryItemLength+=5640605" \
  "D:/MultiMediaTools/variants/neatuhdr_google_xmp.jpg"
```

（可选）把 padding 显式写入以与参考文件一致：

```bash
exiftool -overwrite_original "-XMP-GContainer:DirectoryItemPadding+=0" "D:/MultiMediaTools/variants/neatuhdr_google_xmp.jpg"
```

验证（重要）：

```bash
exiftool -G1 -s -MPImage2:MPImageLength -XMP-GContainer:DirectoryItemLength "D:/MultiMediaTools/variants/neatuhdr_google_xmp.jpg"
```

如果 `DirectoryItemLength` 的第二项等于 `MPImage2:MPImageLength`，则映射一致。

三、创建 b64gain（把 GainMap 以 base64 嵌入 XMP）

背景：尝试直接用 exiftool 写入单个 `XMP-Google:GainMapImage<=file` 会失败（ExifTool 报 `doesn't exist or isn't writable`），因此采用写入完整 XMP 包的方式：先构造一个包含 `<Google:GainMapImage>` 的 XMP packet（内含 base64），然后用 `-XMP:All<=file` 覆盖 XMP 区块。

步骤要点：
1. 从文件中抽出 MPImage2 二进制：

```bash
exiftool -b -MPImage2 "D:/MultiMediaTools/variants/neatuhdr_google_xmp.jpg" > "D:/MultiMediaTools/variants/neatuhdr_mpimage2.bin"
```

2. 用 PowerShell 或脚本将二进制 base64 编码，并把 base64 放到一个完整的 XMP 包中（示例 XMP 存为 `tmp_gain_xmp.xml`）：

示例 XMP（省略长 base64）：

```xml
<?xpacket begin="\uFEFF" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:Google="http://ns.google.com/photos/1.0/">
      <Google:GainMapImage>...BASE64 DATA...</Google:GainMapImage>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
```

3. 把整个 XMP 包写入副本：

示例伪代码（便于移植到任意脚本语言）：

```text
# 伪代码：把 MPImage2 二进制以 base64 嵌入到 XMP，并写入文件的 XMP 区块
INPUT:
  src_jpeg = "D:/MultiMediaTools/variants/neatuhdr_google_xmp_addXMPGain.jpg"  # 源副本
  mpimage_bin = "D:/MultiMediaTools/variants/neatuhdr_mpimage2.bin"         # 已提取的 MPImage2 二进制
  tmp_xmp = "D:/MultiMediaTools/variants/tmp_gain_xmp.xml"                 # 临时 XMP 文件
  dst_jpeg = "D:/MultiMediaTools/variants/neatuhdr_google_xmp_b64gain.jpg" # 目标文件

STEPS:
  1. 复制源到目标（在目标上操作，以保留原始副本不变）
     copy_file(src_jpeg, dst_jpeg)

  2. 读取 MPImage2 二进制并做 base64 编码
     bytes = read_all_bytes(mpimage_bin)
     b64 = base64_encode(bytes)

  3. 构造 XMP 包（xpacket header / x:xmpmeta / rdf:RDF / 描述 / Google:GainMapImage）
     xmp_header = "<?xpacket begin=\"\uFEFF\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
     xmp_footer = "<?xpacket end=\"w\"?>"
     xmp_body = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">" +
                "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" +
                "<rdf:Description rdf:about=\"\" xmlns:Google=\"http://ns.google.com/photos/1.0/\">" +
                "<Google:GainMapImage>" + b64 + "</Google:GainMapImage>" +
                "</rdf:Description></rdf:RDF></x:xmpmeta>"
     full_xmp = xmp_header + NEWLINE + xmp_body + NEWLINE + xmp_footer

  4. 将 full_xmp 以 UTF-8 写入 tmp_xmp（注意写入真实 BOM 或确保解析器兼容转义）
     write_text_file(tmp_xmp, full_xmp, encoding="utf-8")

  5. 用 exiftool 把整个 XMP 包写入目标文件的 XMP 区块
     run("exiftool -overwrite_original \"-XMP:All<=${tmp_xmp}\" \"${dst_jpeg}\"")

  6. 导出并验证元数据
     run("exiftool -json -G1 ${dst_jpeg} > neatuhdr_google_xmp_b64gain.json")
     run("exiftool -v3 ${dst_jpeg} > neatuhdr_google_xmp_b64gain.exif_v3.txt")

  7. （可选）验证 base64 是否与原二进制一致：
     # 解码 tmp_xmp 中的 <Google:GainMapImage> -> decode -> compare bytes with mpimage_bin
     decoded = base64_decode(extract_tag(tmp_xmp, "Google:GainMapImage"))
     assert decoded == bytes

NOTES:
  - 这种方法把 base64 作为 XMP 内容写入（而不是单独用 exiftool 写入不可写的 XMP-Google:GainMapImage 标签）。
  - 写入整个 XMP 包会覆盖目标文件的 XMP 区块；如果文件已有其他自定义 XMP 字段，务必在构造 tmp_xmp 时把它们合并进来以避免丢失。
  - 在不同语言/工具中实现时，保持对大体步骤的一致性：复制 -> 读取 -> base64 -> 构造 XMP -> 写入 -> 验证。
```

示例命令（直接用 exiftool 写入 tmp_xmp）仍然可用：

```bash
exiftool -overwrite_original "-XMP:All<=D:/MultiMediaTools/variants/tmp_gain_xmp.xml" "D:/MultiMediaTools/variants/neatuhdr_google_xmp_b64gain.jpg"
```

4. 导出元数据和详细转储用于验证：

```bash
exiftool -json -G1 "D:/MultiMediaTools/variants/neatuhdr_google_xmp_b64gain.jpg" > "D:/MultiMediaTools/variants/neatuhdr_google_xmp_b64gain.json"
exiftool -v3 "D:/MultiMediaTools/variants/neatuhdr_google_xmp_b64gain.jpg" > "D:/MultiMediaTools/variants/neatuhdr_google_xmp_b64gain.exif_v3.txt"
```

注意：在 JSON 中大块 base64 字段可能不会被展开为单独可读属性，建议直接打开 `tmp_gain_xmp.xml` 查看 `<Google:GainMapImage>` 内容是否被写入。

四、验证建议（比对/提取）

- 从文件中再次尝试抽出 `Google:GainMapImage`（如果解析器/ExifTool 支持）：

```bash
exiftool -b -Google:GainMapImage "D:/MultiMediaTools/variants/neatuhdr_google_xmp_b64gain.jpg" > "out_gain.jpg" || true
```

- 抽出 MPImage2 并对比哈希：

```powershell
# 计算 sha256（Windows）
certutil -hashfile "D:\MultiMediaTools\variants\neatuhdr_mpimage2.bin" SHA256
certutil -hashfile "out_gain.jpg" SHA256
```

五、为什么很多软件只需要 addxmpgain 就够

- 许多实现（包括 Android / Google Photos 的若干版本）会结合 XMP 的 GContainer 数组与 APP2/MPF trailer 中的 MPImageN 找到 GainMap。也就是说，只要 XMP 的 `DirectoryItemSemantic`/`DirectoryItemLength` 指向 MPF 中存在的 MPImage2 payload，解析器就能从 trailer 读取实际的 GainMap 数据并使用它。
- 因此 `addxmpgain`（只写 XMP GContainer 数组并确保 `DirectoryItemLength` 与 `MPImage2:MPImageLength` 一致）通常是最小且兼容性最好的改动，许多软件不需要额外把二进制重复嵌入 XMP。

六、常见问题与注意事项

- PowerShell 引号陷阱：在 PowerShell 使用 exiftool 时，始终把参数整体用引号包起来，例如 `"-XMP-GContainer:DirectoryItemMime+=image/jpeg"`，并使用 `+=` 追加数组元素，避免 `DirectoryItemMime[1]` 这类索引写法。
- 不要对 MPImage2 二进制在原地做二进制编辑；任何尝试修改 trailer 的行为都应在副本上进行并保留原始文件。
- 始终为每次变体保存 `exiftool -v3` 的转储（可用于回溯与审核）。
- 如果 exiftool 报 `Warning: [minor] Error reading GainMap image/jpeg from trailer`，应先检查 `MPImage2:MPImageLength` 与 `XMP-GContainer:DirectoryItemLength` 是否一致，或尝试直接 `-b -MPImage2` 提取 payload 以验证二进制完整性。

七、相关文件清单（本次工作产物）

- `D:\MultiMediaTools\variants\neatuhdr_google_xmp_addXMPGain.jpg`（addxmpgain 变体）
- `D:\MultiMediaTools\variants\neatuhdr_google_xmp_b64gain.jpg`（b64gain 变体）
- `D:\MultiMediaTools\variants\neatuhdr_mpimage2.bin`（提取的 MPImage2 二进制）
- `D:\MultiMediaTools\variants\tmp_gain_xmp.xml`（写入 XMP 的临时 base64 包）
- `D:\MultiMediaTools\variants\neatuhdr_google_xmp_b64gain.json`（b64 变体的 exiftool JSON 导出）
- `D:\MultiMediaTools\variants\neatuhdr_google_xmp_addXMPGain.json`（addxmpgain 变体的 exiftool JSON 导出）

八、备注与下一步建议

- 如果目标是最小改动以获得跨平台识别：优先使用 addxmpgain（确保 DirectoryItemLength 匹配 MPImage2）；只有在目标实现不能从 APP2/MPF trailer 读取时，再考虑 b64gain。
- 如需我把 `tmp_gain_xmp.xml` 中的 base64 解码并与 `neatuhdr_mpimage2.bin` 做字节比对或把生成步骤脚本化为更通用的脚本，我可以进一步处理。

—— 结束
