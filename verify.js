// 컴파일된 index.html 을 진짜 React 로 렌더링해 확인한다.
// Supabase 는 가짜 데이터로 대체하므로 실제 DB 에 영향을 주지 않는다.
//
//   node verify.js index.html /
//   node verify.js index.html /column/110001
//   node verify.js index.html /exam/310001
//   node verify.js index.html /records/wrong --login
//
// 준비: npm i react@18 react-dom@18 jsdom @babel/standalone@7.26.4

const fs = require("fs");
const { JSDOM } = require("jsdom");
const React = require("react");
const ReactDOM = require("react-dom/client");

const file = process.argv[2] || "index.html";
const path = process.argv[3] || "/";
const asMember = process.argv.includes("--login");
const url = "https://example.com" + path;
const html = fs.readFileSync(file, "utf8");

/* ---------- 가짜 데이터 ---------- */
const UID = "test-user";
const COLUMNS = [
  { id: "c1", no: 110001, prev_nos: [], title: "초등 칼럼 하나", body: "<p>본문 A</p>", author: "글쓴이", author_id: UID, is_draft: false, category: "elem", sort_order: 1, created_at: "2026-07-01T00:00:00Z" },
  { id: "c2", no: 120001, prev_nos: [110002], title: "중학으로 옮긴 글", body: "<p>본문 B</p>", author: "글쓴이", author_id: "other", is_draft: false, category: "mid", sort_order: 2, created_at: "2026-07-02T00:00:00Z" },
  { id: "c3", no: 200003, prev_nos: [], title: "중요 공지사항", body: "<p>공지 본문</p>", author: "관리자", author_id: "other", is_draft: false, category: "notice", sort_order: 1, created_at: "2026-07-03T00:00:00Z" },
];
const EXAMS = [
  { id: "e1", no: 310001, prev_nos: [], title: "레벨테스트 1회", exam_type: "level", author: "출제자", author_id: "other", publish_at: null, created_at: "2026-07-01T00:00:00Z",
    questions: [
      { id: "q1", type: "mc", body: [{ id: "s1", type: "text", v: "1+1은?" }], points: 10, options: ["1", "2"], answer: 1 },
      { id: "q2", type: "short", body: [{ id: "s2", type: "text", v: "5+5는?" }], points: 10, accept: "10" },
    ] },
  { id: "e2", no: 320005, prev_nos: [], title: "오늘의 문제 다섯", exam_type: "today", author: "출제자", author_id: "other", publish_at: null, created_at: "2026-07-02T00:00:00Z",
    questions: [{ id: "q3", type: "mc", body: [{ id: "s3", type: "text", v: "3+3은?" }], points: 10, options: ["5", "6"], answer: 1 }] },
];
const SUBS = [
  { id: "s1", exam_id: "e1", student: "테스터", student_id: UID, answers: { q1: 1, q2: "9" }, manual_scores: {}, graded: true, submitted_at: "2026-07-10T00:00:00Z" },
];
const PROFILES = [{ id: UID, username: "테스터", kakao_id: "테스터닉", is_admin: true, is_super: false, created_at: "2026-06-01T00:00:00Z" }];
const DATA = { columns: COLUMNS, exams: EXAMS, submissions: SUBS, profiles: PROFILES, audit_log: [], guest_submissions: [] };
const RPC = {
  exam_stats_all: [
    { exam_id: "e1", total: 8, correct: 4, gtotal: 20, gcorrect: 6 },
    { exam_id: "e2", total: 4, correct: 3, gtotal: 10, gcorrect: 5 },
  ],
  exam_question_stats: [
    { qid: "q1", total: 4, correct: 3, gtotal: 10, gcorrect: 4 },
    { qid: "q2", total: 4, correct: 1, gtotal: 10, gcorrect: 2 },
    { qid: "q3", total: 4, correct: 3, gtotal: 10, gcorrect: 5 },
  ],
  speed_ranking: [{ nickname: "테스터닉", best_score: 1234 }],
  my_speed_rank: [{ my_rank: 1, best_score: 1234, total: 1 }],
};

/* ---------- 브라우저 환경 ---------- */
const dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", { url, pretendToBeVisual: true });
const { window } = dom;
// navigator 처럼 읽기 전용인 전역이 있어 하나씩 안전하게 넣는다
function setGlobal(name, value) {
  try { global[name] = value; }
  catch (e) { Object.defineProperty(global, name, { value, configurable: true, writable: true }); }
}
setGlobal("window", window);
setGlobal("document", window.document);
setGlobal("navigator", window.navigator);
setGlobal("HTMLElement", window.HTMLElement);
setGlobal("Node", window.Node);
setGlobal("getComputedStyle", window.getComputedStyle);
setGlobal("React", React);
setGlobal("ReactDOM", ReactDOM);
setGlobal("requestAnimationFrame", (f) => setTimeout(f, 0));
setGlobal("cancelAnimationFrame", clearTimeout);
setGlobal("alert", () => {});
setGlobal("confirm", () => true);
window.React = React; window.ReactDOM = ReactDOM;
window.alert = global.alert; window.confirm = global.confirm;
const store = {};
const ls = {
  getItem: (k) => (k in store ? store[k] : null),
  setItem: (k, v) => { store[k] = String(v); },
  removeItem: (k) => { delete store[k]; },
};
Object.defineProperty(window, "localStorage", { value: ls, configurable: true });
global.localStorage = ls;
window.katex = { renderToString: (s) => "<span>" + s + "</span>" };
window.MathfieldElement = function () {};

/* ---------- 가짜 Supabase ---------- */
function chain(table, single) {
  const rows = DATA[table] || [];
  const p = Promise.resolve({ data: single ? rows[0] || null : rows, error: null });
  return new Proxy(function () {}, {
    get(_t, prop) {
      if (prop === "then") return p.then.bind(p);
      if (prop === "catch") return p.catch.bind(p);
      if (prop === "finally") return p.finally.bind(p);
      if (prop === "maybeSingle" || prop === "single") return () => chain(table, true);
      return () => chain(table, single);
    },
  });
}
const session = asMember
  ? { user: { id: UID, email: "테스터@mathroom.app", user_metadata: { username: "테스터" } } }
  : null;
window.supabase = {
  createClient: () => ({
    auth: {
      getSession: async () => ({ data: { session } }),
      getUser: async () => ({ data: { user: session ? session.user : null } }),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      signOut: async () => ({}),
      signInWithPassword: async () => ({ data: null, error: { message: "x" } }),
      signUp: async () => ({ data: null, error: { message: "x" } }),
      updateUser: async () => ({ error: null }),
    },
    from: (t) => chain(t),
    rpc: (name) => (RPC[name] ? Promise.resolve({ data: RPC[name], error: null }) : chain("_none")),
    storage: { from: () => chain("_none") },
  }),
};

/* ---------- 실행 ---------- */
const errors = [];
const log = console.log.bind(console);
console.error = (...a) => errors.push(a.join(" "));
window.addEventListener("error", (e) => errors.push("onerror: " + e.message));
process.on("unhandledRejection", (r) => errors.push("unhandledRejection: " + r));

const m = html.match(/<script>\n(\(function\(\)\{[\s\S]*?)\n<\/script>/);
if (!m) { log("컴파일된 스크립트를 찾지 못했습니다. build.js 로 만든 파일이 맞는지 확인하세요."); process.exit(1); }
try {
  new Function("window", "document", "React", "ReactDOM", "localStorage", "alert", "confirm", m[1])(
    window, window.document, React, ReactDOM, ls, global.alert, global.confirm
  );
} catch (e) {
  log("실행 중 예외:", e.message);
  process.exit(1);
}
window.document.dispatchEvent(new window.Event("DOMContentLoaded", { bubbles: true }));

setTimeout(() => {
  const root = window.document.getElementById("root");
  const text = root.textContent || "";
  const inner = root.innerHTML || "";
  log("주소  :", path, asMember ? "(로그인 상태)" : "(비로그인)");
  log("  렌더링   :", inner.length > 1000 ? "OK " + inner.length + "자" : "비어있음 X");
  log("  헤더     :", text.includes("수학질문방") ? "OK" : "안 보임 X");
  const title = (text.match(/[^\s]{2,}(칼럼|공지사항|시험|기록|관리자|처리방침|업데이트 내역|연산)/) || [])[0];
  if (title) log("  화면     :", title);
  const rate = (text.match(/평균정답률\s*[\d—]+%?/) || [])[0];
  if (rate) log("  정답률   :", rate);
  if (text.includes("로그인하기") && path.indexOf("/column") === 0) log("  칼럼     : 로그인 안내 표시 (비회원 정상)");

  const real = errors.filter((e) => !/scrollTo|Not implemented|act\(|Warning:/i.test(e));
  log("  에러     :", real.length === 0 ? "없음 OK" : real.length + "건");
  real.slice(0, 3).forEach((e) => log("     - " + e.slice(0, 160)));
  process.exit(real.length ? 1 : 0);
}, 1500);
