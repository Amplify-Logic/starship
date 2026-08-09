#!/usr/bin/env node
// Self-contained Markdown-to-HTML renderer for fm-read.sh.
// It intentionally escapes raw HTML and supports the report-oriented Markdown
// surface used by Firstmate: headings, paragraphs, emphasis, links and images
// restricted to http/https/mailto/relative targets, blockquotes, lists, fenced
// code, pipe tables, and thematic breaks of three or more dashes, asterisks, or
// underscores, whether or not they are separated by spaces.
// A list item owns every following line indented past its own marker, and that
// block is rendered as Markdown in its own right, so nested lists, tables,
// rules, quotes, and fenced code stay inside the item they document.
// The known limits are that a continuation must be indented, so an unindented
// line after a list ends the list rather than continuing its last item; that a
// continuation which is a single paragraph joins the item's own line while any
// richer continuation renders as blocks after it; and that setext headings,
// reference-style links, four-space code blocks, task-list checkboxes, and
// two-space hard line breaks are not recognised anywhere.
// Headings carry GitHub-style anchor ids slugged from their visible text and
// de-duplicated within the page by numeric suffix, so in-document
// table-of-contents links resolve and scroll.
// Literal NUL bytes are stripped before parsing, so document content can never
// forge the NUL-delimited placeholder markers used for stashed code and tags.
// It also owns the private page naming: the page is written 0600 under a 0700
// output directory and its path is printed on stdout.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const [sourceArg, outputDirArg] = process.argv.slice(2);
if (!sourceArg || !outputDirArg) {
  console.error("usage: fm-read.mjs <source.md> <output-dir>");
  process.exit(2);
}

const CODE_MARK = String.fromCharCode(0);

const escapeHtml = (value) => value
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;")
  .replaceAll("'", "&#39;");

function safeUrl(href) {
  const probe = href.replace(/[^\x21-\x7E]/g, "").toLowerCase();
  if (!/^[a-z][a-z0-9+.-]*:/.test(probe)) return href;
  return /^(?:https?|mailto):/.test(probe) ? href : "";
}

const anchorIds = new Set();

function anchorId(text) {
  const plain = text
    .replace(/`([^`]*)`/g, "$1")
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1");
  const base = plain.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "section";
  let id = base;
  for (let n = 1; anchorIds.has(id); n += 1) id = `${base}-${n}`;
  anchorIds.add(id);
  return id;
}

function inline(value) {
  const code = [];
  const slot = (markup) => {
    code.push(markup);
    return `${CODE_MARK}CODE${code.length - 1}${CODE_MARK}`;
  };
  let text = value.replace(/`([^`]+)`/g, (_match, body) => slot(`<code>${escapeHtml(body)}</code>`));
  text = escapeHtml(text);
  text = text.replace(/!\[([^\]]*)\]\(([^\s)]+)(?:\s+&quot;([^&]*)&quot;)?\)/g,
    (_match, alt, href, title) => {
      const src = safeUrl(href);
      return src ? slot(`<img src="${src}" alt="${alt}"${title ? ` title="${title}"` : ""}>`) : alt;
    });
  text = text.replace(/\[([^\]]+)\]\(([^\s)]+)(?:\s+&quot;([^&]*)&quot;)?\)/g,
    (_match, label, href, title) => {
      const url = safeUrl(href);
      if (!url) return label;
      return `${slot(`<a href="${url}"${title ? ` title="${title}"` : ""}>`)}${label}${slot("</a>")}`;
    });
  text = text.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  text = text.replace(/(^|[^\w])__([^_]+)__(?!\w)/g, "$1<strong>$2</strong>");
  text = text.replace(/(^|[^\w*])\*([^*]+)\*(?!\w)/g, "$1<em>$2</em>");
  text = text.replace(/(^|[^\w])_([^_]+)_(?!\w)/g, "$1<em>$2</em>");
  text = text.replace(/~~([^~]+)~~/g, "<del>$1</del>");
  for (let index = code.length - 1; index >= 0; index -= 1) {
    text = text.replaceAll(`${CODE_MARK}CODE${index}${CODE_MARK}`, () => code[index]);
  }
  return text;
}

function tableCells(line) {
  let value = line.trim();
  if (value.startsWith("|")) value = value.slice(1);
  if (value.endsWith("|")) value = value.slice(0, -1);
  return value.split(/(?<!\\)\|/).map((cell) => cell.trim().replaceAll("\\|", "|"));
}

function isTableDivider(line, columns) {
  if (!line.includes("|")) return false;
  const cells = tableCells(line);
  return cells.length === columns && cells.every((cell) => /^:?-+:?$/.test(cell));
}

function indentWidth(line) {
  return line.match(/^[ \t]*/)[0].replaceAll("\t", "  ").length;
}

function dedent(block) {
  let common = Infinity;
  for (const line of block) if (line.trim()) common = Math.min(common, indentWidth(line));
  if (!Number.isFinite(common) || common === 0) return block;
  return block.map((line) => {
    if (!line.trim()) return "";
    let dropped = 0;
    let index = 0;
    while (index < line.length && dropped < common && (line[index] === " " || line[index] === "\t")) {
      dropped += line[index] === "\t" ? 2 : 1;
      index += 1;
    }
    return line.slice(index);
  });
}

function render(markdown) {
  const lines = markdown.replaceAll("\u0000", "").replaceAll("\r\n", "\n").replaceAll("\r", "\n").split("\n");
  const out = [];
  let paragraph = [];
  let list = null;
  let quote = [];
  let itemLines = [];

  const flushParagraph = () => {
    if (paragraph.length) out.push(`<p>${inline(paragraph.join(" ").trim())}</p>`);
    paragraph = [];
  };
  const openItem = () => list !== null && list.open;
  const flushItemBlock = () => {
    if (!itemLines.length) return;
    const block = render(dedent(itemLines).join("\n"));
    itemLines = [];
    const lone = block.startsWith("<p>") && block.endsWith("</p>") && !block.slice(3, -4).includes("</p>");
    const content = lone ? block.slice(3, -4) : block;
    if (content) out.push(content);
  };
  const closeList = () => {
    if (!list) return;
    flushItemBlock();
    if (list.open) out.push("</li>");
    out.push(`</${list.type}>`);
    list = null;
  };
  const flushQuote = () => {
    if (quote.length) out.push(`<blockquote>${render(quote.join("\n"))}</blockquote>`);
    quote = [];
  };
  const flushBlocks = () => {
    flushParagraph();
    closeList();
    flushQuote();
  };
  const nextContent = (from) => {
    for (let j = from; j < lines.length; j += 1) if (lines[j].trim()) return j;
    return -1;
  };

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const blank = !line.trim();
    if (openItem()) {
      const next = blank ? nextContent(i + 1) : i;
      if (next >= 0 && indentWidth(lines[next]) > list.indent) {
        itemLines.push(line);
        continue;
      }
    }
    if (blank) {
      flushParagraph();
      flushItemBlock();
      flushQuote();
      continue;
    }
    const fence = line.match(/^([ \t]*)```([^`]*)$/);
    if (fence) {
      flushBlocks();
      const width = fence[1].length;
      const body = [];
      i += 1;
      while (i < lines.length && !/^[ \t]*```[ \t]*$/.test(lines[i])) {
        body.push(lines[i].slice(Math.min(lines[i].match(/^[ \t]*/)[0].length, width)));
        i += 1;
      }
      const language = fence[2].trim().replace(/[^A-Za-z0-9_-]/g, "");
      out.push(`<pre><code${language ? ` class="language-${language}"` : ""}>${escapeHtml(body.join("\n"))}</code></pre>`);
      continue;
    }
    const heading = line.match(/^(#{1,6})\s+(.+?)\s*#*$/);
    if (heading) {
      flushBlocks();
      const level = heading[1].length;
      out.push(`<h${level} id="${anchorId(heading[2])}">${inline(heading[2])}</h${level}>`);
      continue;
    }
    const headers = line.includes("|") ? tableCells(line) : null;
    if (headers && i + 1 < lines.length && isTableDivider(lines[i + 1], headers.length)) {
      flushBlocks();
      const alignments = tableCells(lines[i + 1]).map((cell) => cell.startsWith(":") && cell.endsWith(":") ? "center" : cell.endsWith(":") ? "right" : "left");
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].includes("|") && lines[i].trim()) {
        rows.push(tableCells(lines[i]));
        i += 1;
      }
      i -= 1;
      out.push("<div class=\"tw\"><table><thead><tr>");
      headers.forEach((cell, index) => out.push(`<th style="text-align:${alignments[index] || "left"}">${inline(cell)}</th>`));
      out.push("</tr></thead><tbody>");
      rows.forEach((row) => {
        out.push("<tr>");
        const width = Math.max(headers.length, row.length);
        for (let cell = 0; cell < width; cell += 1) {
          out.push(`<td style="text-align:${alignments[cell] || "left"}">${inline(row[cell] || "")}</td>`);
        }
        out.push("</tr>");
      });
      out.push("</tbody></table></div>");
      continue;
    }
    if (/^[ \t]*(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$/.test(line)) {
      flushBlocks();
      out.push("<hr>");
      continue;
    }
    const quoteLine = line.match(/^>\s?(.*)$/);
    if (quoteLine) {
      flushParagraph();
      closeList();
      quote.push(quoteLine[1]);
      continue;
    }
    if (quote.length) flushQuote();
    const unordered = line.match(/^([ \t]*)[-+*][ \t]+(.+)$/);
    const ordered = line.match(/^([ \t]*)\d+[.)][ \t]+(.+)$/);
    if (unordered || ordered) {
      flushParagraph();
      flushItemBlock();
      const [, pad, content] = unordered || ordered;
      const type = unordered ? "ul" : "ol";
      if (list && list.type !== type) closeList();
      if (!list) {
        list = { type, indent: 0, open: false };
        out.push(`<${type}>`);
      }
      if (list.open) out.push("</li>");
      out.push(`<li>${inline(content)}`);
      list.indent = pad.replaceAll("\t", "  ").length;
      list.open = true;
      continue;
    }
    closeList();
    paragraph.push(line.trim());
  }
  flushBlocks();
  return out.join("\n");
}

const css = `
:root{--ink:#f2efe9;--dim:#a9a394;--line:#2b2f3a;--bg:#0e1116;--card:#161a22;--accent:#7aa7ff}
@media (prefers-color-scheme:light){:root{--ink:#1a1c20;--dim:#5d6470;--line:#e2dfd8;--bg:#fbfaf7;--card:#fff;--accent:#2f5fd0}}
:root[data-theme="dark"]{--ink:#f2efe9;--dim:#a9a394;--line:#2b2f3a;--bg:#0e1116;--card:#161a22;--accent:#7aa7ff}
:root[data-theme="light"]{--ink:#1a1c20;--dim:#5d6470;--line:#e2dfd8;--bg:#fbfaf7;--card:#fff;--accent:#2f5fd0}
*{box-sizing:border-box}html{overflow-x:hidden}body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.72 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,sans-serif;overflow-wrap:anywhere}
main{max-width:820px;margin:0 auto;padding:52px 24px 110px;min-width:0}h1,h2,h3,h4,h5,h6{line-height:1.34;padding-bottom:4px}
h1{font-size:2.3rem;letter-spacing:-.4px;margin:0 0 22px}h2{font-size:1.5rem;margin:46px 0 12px;letter-spacing:-.2px;border-bottom:1px solid var(--line);padding-top:6px}
h3{font-size:1.14rem;margin:30px 0 8px}h4,h5,h6{font-size:1rem;margin:22px 0 6px;color:var(--dim);text-transform:uppercase;letter-spacing:.6px}
p,li{max-width:74ch}p{margin:0 0 15px}ul,ol{padding-left:22px;margin:0 0 15px}li{margin-bottom:7px}li>ul,li>ol{margin:7px 0 0}strong{font-weight:680}a{color:var(--accent)}
hr{border:0;border-top:1px solid var(--line);margin:40px 0}blockquote{margin:16px 0;padding:2px 0 2px 18px;border-left:3px solid var(--accent);color:var(--dim)}
code{background:rgba(127,127,127,.16);padding:1px 6px;border-radius:5px;font-size:.87em;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-word}
pre{max-width:100%;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:15px 17px;overflow-x:auto;margin:16px 0;line-height:1.55}pre code{background:none;padding:0;font-size:.85rem;word-break:normal}
.tw{max-width:100%;overflow-x:auto;margin:18px 0;border:1px solid var(--line);border-radius:10px}table{border-collapse:collapse;width:100%;min-width:420px;font-size:.95rem}
th,td{text-align:left;padding:11px 15px;border-bottom:1px solid var(--line);vertical-align:top}th{background:rgba(127,127,127,.09);font-size:.79rem;text-transform:uppercase;letter-spacing:.5px;color:var(--dim)}tr:last-child td{border-bottom:0}img{max-width:100%;height:auto}
`;
try {
  const source = fs.realpathSync(sourceArg);
  const body = render(fs.readFileSync(source, "utf8"));
  const stem = path.basename(source, path.extname(source));
  const parent = path.basename(path.dirname(source));
  const label = stem.toLowerCase() === "report" && parent ? parent : stem;
  const slug = label.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "report";
  const digest = crypto.createHash("sha256").update(source).digest("hex").slice(0, 10);
  const title = escapeHtml(label.replaceAll("-", " ").replace(/\b\w/g, (letter) => letter.toUpperCase()));
  const html = `<!doctype html>\n<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title><style>${css}</style></head><body><main>\n${body}\n</main></body></html>\n`;
  const outputDir = path.resolve(outputDirArg);
  const output = path.join(outputDir, `read-${slug}-${digest}.html`);
  fs.mkdirSync(outputDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(outputDir, 0o700);
  fs.writeFileSync(output, html, { mode: 0o600 });
  fs.chmodSync(output, 0o600);
  process.stdout.write(`${output}\n`);
} catch (err) {
  console.error(`fm-read.mjs: ${err.message}`);
  process.exit(1);
}
