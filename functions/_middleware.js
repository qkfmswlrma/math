// ============================================================
// 카톡·메신저 링크 미리보기
//
// /column/110001, /notice/200003, /exam/310001 같은 주소로 들어오면
// 그 글·시험의 제목을 미리보기(og 태그)에 넣어서 돌려준다.
// 그 외 주소는 손대지 않고 그대로 통과시킨다.
//
// 파일 위치: 저장소 맨 위의 functions/_middleware.js
// ============================================================

const SUPABASE_URL = "https://fhdwwqlvosbjonrenpqz.supabase.co";
const SUPABASE_ANON_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZoZHd3cWx2b3Niam9ucmVucHF6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAzMTk4NzYsImV4cCI6MjA5NTg5NTg3Nn0.JgUEKxDRioqKvhSaOPxJMH9tuo0wdFv0-kkc0s5mJ8U";

const SITE_NAME = "수학질문방";
const DEFAULT_DESC = "칼럼과 시험으로 함께 공부하는 수학 커뮤니티";

// 본문 HTML → 미리보기용 짧은 글
function summarize(html, limit) {
  const t = String(html || "")
    .replace(/<[^>]*>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
  if (!t) return "";
  return t.length > limit ? t.slice(0, limit) + "…" : t;
}

function keyHeaders() {
  return {
    apikey: SUPABASE_ANON_KEY,
    Authorization: "Bearer " + SUPABASE_ANON_KEY,
    Accept: "application/json",
  };
}

async function sb(path) {
  const res = await fetch(SUPABASE_URL + "/rest/v1/" + path, { headers: keyHeaders() });
  if (!res.ok) return null;
  const rows = await res.json();
  return Array.isArray(rows) && rows.length ? rows[0] : null;
}

// 칼럼은 회원 전용이라 표를 직접 읽을 수 없다.
// 미리보기에 쓸 제목만 내주는 함수를 따로 부른다.
async function sbRpc(name, args) {
  const res = await fetch(SUPABASE_URL + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: Object.assign({ "Content-Type": "application/json" }, keyHeaders()),
    body: JSON.stringify(args || {}),
  });
  if (!res.ok) return null;
  const data = await res.json();
  return data && typeof data === "object" ? data : null;
}

// 옛 번호(prev_nos)로 들어와도 찾도록
function noFilter(no) {
  return "or=(no.eq." + no + ",prev_nos.cs.%7B" + no + "%7D)";
}

async function lookup(kind, no) {
  try {
    if (kind === "exam") {
      const r = await sb("exams?" + noFilter(no) + "&select=title,author&limit=1");
      if (!r) return null;
      return {
        title: r.title + " · 시험",
        desc: (r.author ? "출제 " + r.author + " · " : "") + "지금 풀어보세요",
      };
    }
    // 공지는 표에서 바로 읽힌다. 칼럼은 안 읽히므로 제목만 주는 함수로 물어본다
    let r = await sb("columns?" + noFilter(no) + "&select=title,body,author,category&limit=1");
    if (!r) r = await sbRpc("post_preview", { p_no: Number(no) });
    if (!r || !r.title) return null;
    const label = r.category === "notice" ? "공지사항" : "칼럼";
    return {
      title: r.title + " · " + label,
      desc: summarize(r.body, 80) || (r.author ? r.author + "님의 글" : DEFAULT_DESC),
    };
  } catch (e) {
    return null;
  }
}

// og 태그와 <title> 만 갈아끼우는 도구
class MetaSetter {
  constructor(map) {
    this.map = map;
  }
  element(el) {
    const key = el.getAttribute("property") || el.getAttribute("name");
    if (key && Object.prototype.hasOwnProperty.call(this.map, key)) {
      el.setAttribute("content", this.map[key]);
    }
  }
}
class TitleSetter {
  // 주의: HTMLRewriter 가 handlers.text 를 함수로 기대하므로
  //       속성 이름에 text 를 쓰면 안 된다.
  constructor(value) {
    this.value = value;
  }
  element(el) {
    el.setInnerContent(this.value);
  }
}

export async function onRequest(context) {
  // 미리보기 처리 중 무슨 문제가 생겨도 사이트는 정상 동작해야 한다
  try {
    return await handle(context);
  } catch (e) {
    return context.next();
  }
}

async function handle(context) {
  const { request, next } = context;
  const url = new URL(request.url);
  const m = url.pathname.match(/^\/(column|notice|exam)\/(\d+)\/?$/);

  const res = await next();
  if (!m) return res;

  const ct = res.headers.get("content-type") || "";
  if (!ct.includes("text/html")) return res;

  let info = await lookup(m[1], m[2]);
  if (!info) {
    // 칼럼은 회원 전용이라 제목을 읽어올 수 없다 → 안내용 미리보기
    if (m[1] === "column") {
      info = { title: SITE_NAME + " 칼럼", desc: "로그인하면 읽을 수 있어요" };
    } else {
      return res; // 그 외(없는 글 등)는 기본 미리보기 그대로
    }
  }

  const meta = {
    "og:title": info.title,
    "og:description": info.desc,
    "og:url": url.origin + url.pathname,
    "og:site_name": SITE_NAME,
    "twitter:title": info.title,
    "twitter:description": info.desc,
    description: info.desc,
  };

  return new HTMLRewriter()
    .on("meta", new MetaSetter(meta))
    .on("title", new TitleSetter(info.title))
    .transform(res);
}
