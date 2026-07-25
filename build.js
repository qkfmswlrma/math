// _source.html (JSX 원본) -> index.html (브라우저가 바로 실행하는 컴파일본)
// 사용법: node build.js _source.html index.html
const fs = require("fs");
const Babel = require("@babel/standalone");

const [, , inPath, outPath] = process.argv;
let html = fs.readFileSync(inPath, "utf8");

// 1) JSX 블록 추출
const re = /<script type="text\/babel"[^>]*>([\s\S]*?)<\/script>/;
const m = html.match(re);
if (!m) { console.error("JSX 블록을 찾지 못했습니다."); process.exit(1); }

// 2) 컴파일 (classic 런타임 = React.createElement, import 없음)
const compiled = Babel.transform(m[1], {
  presets: ["react"],
  generatorOpts: { jsescOption: { minimal: true } }, // 한글을 \uXXXX 로 바꾸지 않음
}).code;

// 3) 안전장치: 컴파일 결과에 import/export 가 있으면 중단
if (/^\s*(import|export)\s/m.test(compiled)) {
  console.error("컴파일 결과에 import/export 가 있습니다. 중단합니다.");
  process.exit(1);
}

// 4) defer 로 로드되는 React/Supabase/KaTeX/MathLive 가 준비된 뒤 실행되도록 감싼다.
//    (일반 <script> 는 즉시 실행돼서 그대로 두면 window.supabase 가 없어 깨짐)
const wrapped =
  "(function(){\n" +
  "function __boot(){\n" +
  compiled +
  "\n}\n" +
  "if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', __boot);\n" +
  "else __boot();\n" +
  "})();";

html = html.replace(re, "<script>\n" + wrapped + "\n</script>");

// 5) Babel CDN 제거 (더 이상 필요 없음)
html = html.replace(/\s*<script[^>]*babel[^>]*><\/script>/gi, "");

fs.writeFileSync(outPath, html);

const kb = (s) => Math.round(Buffer.byteLength(s) / 1024);
console.log("빌드 완료:", outPath);
console.log("  원본   ", kb(fs.readFileSync(inPath, "utf8")), "KB");
console.log("  배포본 ", kb(html), "KB");
console.log("  Babel 태그 남음:", /babel/i.test(html) ? "예(확인필요)" : "아니오");
