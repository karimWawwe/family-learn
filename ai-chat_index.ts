// Family Learn - AI gateway (Supabase Edge Function "ai-chat").
//
// The ONLY place that talks to Claude (Anthropic API). The API key is the Edge Function
// secret ANTHROPIC_API_KEY; it never reaches the app or the database.
//
// POST body (JSON):
//   {"profile_id": "...", "kind": "tutor" | "roleplay" | "feedback",
//    "conversation_id": "..." (optional), "context": {...} (optional), "message": "..." (optional)}
// Reply: {"conversation_id", "reply"?, "feedback"?, "flagged"?, "remaining_today"?}  or  {"error": "<code>"}
//
// Steps: ai_prepare() as the signed-in user (access, limits, budget, saves the message)
//        -> Claude -> ai_finish() with the secret key (saves reply, tokens, cost, safety flag).
// No external imports: plain fetch, so it deploys from the dashboard editor as one file.

export const MODEL = "claude-haiku-5-5";
// USD per token (Claude Haiku 5.5, prompts up to 100k tokens: $0.10 / $0.50 per million)
const PRICE_IN = 0.10 / 1_000_000;
const PRICE_OUT = 0.50 / 1_000_000;
const FLAG = "[FLAG]";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Json = Record<string, unknown>;
export type Env = (name: string) => string | undefined;

export interface Prepared {
  conversation_id: string;
  kind: "tutor" | "roleplay" | "feedback";
  cached_feedback?: Json;
  profile: { name: string; kind: "adult" | "child"; grade: number | null; ui_locale: "en" | "ar" };
  scenario: { code: string; lang: "en" | "fr"; title: string; persona: string; goal: string } | null;
  context: Json;
  history: { role: "user" | "assistant"; content: string }[];
  remaining_today: number;
}

function reply(body: Json, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

/** Keys: new projects have SUPABASE_*_KEYS JSON dictionaries; older ones the legacy names. */
export function keys(env: Env): { publishable: string; secret: string } {
  const pick = (json: string | undefined, legacy: string | undefined) => {
    if (json) {
      try {
        const d = JSON.parse(json) as Record<string, string>;
        if (d["default"]) return d["default"];
        const first = Object.values(d)[0];
        if (first) return first;
      } catch (_) { /* fall back to the legacy key */ }
    }
    return legacy ?? "";
  };
  return {
    publishable: pick(env("SUPABASE_PUBLISHABLE_KEYS"), env("SUPABASE_ANON_KEY")),
    secret: pick(env("SUPABASE_SECRET_KEYS"), env("SUPABASE_SERVICE_ROLE_KEY")),
  };
}

async function rpc(fetcher: typeof fetch, url: string, fn: string, args: Json, headers: Record<string, string>) {
  const r = await fetcher(`${url}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { ...headers, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const text = await r.text();
  let data: unknown = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch (_) {
    data = text;
  }
  if (!r.ok) {
    const msg = (data as Json | null)?.message;
    throw new GatewayError(typeof msg === "string" ? msg : `rpc_${r.status}`, r.status);
  }
  return data;
}

export class GatewayError extends Error {
  constructor(public code: string, public status = 400) {
    super(code);
  }
}

// ------------------------------------------------------------------ prompts
function levelOf(p: Prepared["profile"]): string {
  if (p.kind === "adult") return "an adult learner (B1-B2 English) who works as a sales manager in perfume retail in Oman";
  const g = p.grade ?? 3;
  if (g <= 3) return `a ${g + 6}-year-old child in grade ${g} (beginner, A0-A1): use very short, simple sentences and common words`;
  return `a ${g + 6}-year-old child in grade ${g} (A1-A2): use short, clear sentences`;
}

const SAFETY = `
Child safety rules (always):
- Be kind, patient, encouraging and age-appropriate. Never scary, violent, romantic or adult content.
- Never ask for or repeat personal information (full name, address, school name, phone, passwords, photos, location).
- Do not chat about topics unrelated to learning; gently bring the child back to the lesson.
- If the child writes about being hurt, in danger, very sad, bullied, or shares personal information, answer kindly and
  tell them to talk to their parent or teacher now. In that case start your reply with ${FLAG} (the app hides it and tells the parent).
- Also start with ${FLAG} if the child's message contains bad words or inappropriate content.`;

const RELIGION = `
For Islamic studies: never invent or paraphrase a Quran verse or a hadith as a quote and never give religious rulings
beyond the lesson; explain the meaning simply and suggest asking the teacher or a parent for details.`;

export function systemPrompt(p: Prepared): string {
  const pr = p.profile;
  const replyLang = pr.kind === "child" && pr.ui_locale === "ar"
    ? "Reply in simple Arabic (Modern Standard, child-friendly). Keep English or French words in their own language and give their meaning."
    : pr.kind === "child"
    ? "Reply in simple English. You may add a short Arabic meaning for hard words in brackets."
    : "Reply in clear, natural English. If he writes in Arabic, answer in Arabic.";

  if (p.kind === "roleplay" || p.kind === "feedback") {
    const s = p.scenario!;
    const lang = s.lang === "fr" ? "French" : "English";
    if (p.kind === "feedback") {
      return `You are a friendly ${lang} teacher. The learner is ${levelOf(pr)}.
They just finished a role-play: "${s.title}". Their goal was: ${s.goal}.
Write feedback on the LEARNER's messages only, as JSON, with no text before or after it:
{"summary": "2-3 encouraging sentences: what went well and one thing to improve",
 "goal_reached": true or false,
 "grammar": [["what they wrote", "corrected version"]],
 "better_words": [["their word or phrase", "a better or more natural one"]],
 "phrases": ["useful ${lang} phrases for this situation"],
 "new_words": ["${lang} word — meaning"]}
At most 4 items in each list; empty lists are fine. Only correct real mistakes.
${pr.kind === "child" && pr.ui_locale === "ar" ? "Write \"summary\" and the word meanings in simple Arabic; keep the " + lang + " examples in " + lang + "." : "Write the summary in English."}
${pr.kind === "child" ? SAFETY : ""}`;
    }
    return `Role-play practice in ${lang}. You play: ${s.persona}. Stay in character.
The learner is ${levelOf(pr)}. Their goal: ${s.goal}.
- Speak ONLY ${lang}, matched to the learner's level. 1-3 short sentences per turn.
- Do not correct mistakes during the conversation (feedback comes at the end); just keep the conversation natural.
- Help the learner reach the goal: ask simple questions, react to what they say.
- If the learner is stuck or writes in Arabic, give a short hint in ${lang} with a very simple example sentence they can use.
- When the goal is clearly reached, close the conversation naturally in one sentence.
${pr.kind === "child" ? SAFETY : ""}`;
  }

  // tutor
  const c = p.context as Record<string, unknown>;
  const lines: string[] = [];
  if (c.course) lines.push(`Course: ${c.course} (${c.subject})`);
  if (c.lesson) lines.push(`Lesson: ${c.lesson}`);
  const intro = c.lesson_intro as Json | null | undefined;
  if (intro && typeof intro === "object") {
    const ex = intro.explain ? `Lesson explanation: ${intro.explain}` : "";
    const vocab = Array.isArray(intro.vocab)
      ? `Lesson words: ${(intro.vocab as Json[]).map((v) => `${v.w} = ${v.ar}`).join("; ")}`
      : "";
    if (ex) lines.push(ex);
    if (vocab) lines.push(vocab);
  }
  if (c.question) {
    lines.push(`Question the learner is working on: ${c.question}`);
    if (c.passage) lines.push(`Passage: ${c.passage}`);
    if (Array.isArray(c.options)) lines.push(`Options: ${(c.options as string[]).join(" | ")}`);
    if (c.before || c.after) lines.push(`Sentence: ${c.before ?? ""} ____ ${c.after ?? ""}`);
    if (c.answered) {
      lines.push(`The learner already answered and was ${c.learner_was_right ? "right" : "wrong"}.`);
      lines.push(`Correct answer: ${c.correct_answer}`);
      if (c.explanation) lines.push(`Book explanation: ${c.explanation}`);
    } else {
      lines.push("The learner has NOT answered yet: do NOT give the answer. Give a hint and guide them step by step.");
    }
  }
  const subject = String(c.subject ?? "");
  return `You are the friendly AI tutor in "Family Learn", a family learning app (Egyptian curriculum, language schools).
The learner is ${levelOf(pr)}. ${replyLang}
How to help:
- Explain step by step with one short example. Keep answers short (under 120 words) unless asked for more.
- When the learner made a mistake, explain WHY the right answer is right and what to notice next time. Be encouraging.
- Teach, don't just answer: for homework-like questions, guide with hints and ask the learner to try.
- Stay on the course topic. Use only facts you are sure about; if unsure, say so.
${subject === "religion" ? RELIGION : ""}
${pr.kind === "child" ? SAFETY : ""}
${lines.length ? "\nContext from the app:\n" + lines.join("\n") : ""}`;
}

/** Messages for Claude: must start with the user and alternate. */
export function chatMessages(p: Prepared): { role: "user" | "assistant"; content: string }[] {
  const out: { role: "user" | "assistant"; content: string }[] = [];
  for (const m of p.history) {
    if (!m.content?.trim()) continue;
    const last = out[out.length - 1];
    if (last && last.role === m.role) last.content += "\n" + m.content;
    else out.push({ role: m.role, content: m.content });
  }
  if (p.kind === "feedback") {
    const transcript = out.map((m) => `${m.role === "user" ? "LEARNER" : "PARTNER"}: ${m.content}`).join("\n");
    return [{ role: "user", content: `Role-play transcript:\n${transcript}\n\nWrite the JSON feedback now.` }];
  }
  if (out.length === 0 || out[0].role !== "user") {
    out.unshift({ role: "user", content: "(Start the role-play now: say your first line.)" });
  }
  if (out[out.length - 1].role !== "user") out.push({ role: "user", content: "(continue)" });
  return out;
}

export function parseFeedback(text: string): Json {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  let f: Json = {};
  if (start >= 0 && end > start) {
    try {
      f = JSON.parse(text.slice(start, end + 1));
    } catch (_) {
      f = {};
    }
  }
  const pairs = (v: unknown) =>
    Array.isArray(v)
      ? v.filter((x) => Array.isArray(x) && x.length >= 2).slice(0, 6).map((x) => [String(x[0]), String(x[1])])
      : [];
  const strs = (v: unknown) => (Array.isArray(v) ? v.map(String).filter((s) => s.trim()).slice(0, 8) : []);
  return {
    summary: typeof f.summary === "string" && f.summary.trim() ? f.summary : text.replace(/[{}]/g, "").trim().slice(0, 600),
    goal_reached: f.goal_reached === true,
    grammar: pairs(f.grammar),
    better_words: pairs(f.better_words),
    phrases: strs(f.phrases),
    new_words: strs(f.new_words),
  };
}

// ------------------------------------------------------------------ handler
export async function handle(req: Request, env: Env, fetcher: typeof fetch = fetch): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply({ error: "bad_request" }, 405);

  const apiKey = env("ANTHROPIC_API_KEY");
  if (!apiKey) return reply({ error: "ai_not_configured" }, 503);
  const url = env("SUPABASE_URL") ?? "";
  const k = keys(env);
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return reply({ error: "not_signed_in" }, 401);

  let body: Json;
  try {
    body = await req.json();
  } catch (_) {
    return reply({ error: "bad_request" }, 400);
  }
  const kind = body.kind;
  if (kind !== "tutor" && kind !== "roleplay" && kind !== "feedback") return reply({ error: "bad_request" }, 400);

  try {
    // 1) as the user: access + limits + save the message
    const prep = await rpc(fetcher, url, "ai_prepare", {
      p_profile: body.profile_id,
      p_kind: kind,
      p_conversation: body.conversation_id ?? null,
      p_context: body.context ?? {},
      p_message: typeof body.message === "string" ? body.message : null,
    }, { apikey: k.publishable, Authorization: auth }) as Prepared;

    if (prep.cached_feedback) return reply({ conversation_id: prep.conversation_id, feedback: prep.cached_feedback });

    // 2) Claude
    const r = await fetcher("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: kind === "feedback" ? 900 : prep.profile.kind === "child" ? 350 : 500,
        system: systemPrompt(prep),
        messages: chatMessages(prep),
      }),
    });
    const data = await r.json().catch(() => ({})) as Json;
    if (!r.ok) {
      const type = ((data.error as Json | undefined)?.type as string | undefined) ?? "";
      console.error("anthropic error", r.status, JSON.stringify(data).slice(0, 300));
      const code = r.status === 401 || type === "authentication_error"
        ? "ai_key_invalid"
        : r.status === 429 || r.status === 529 || type === "overloaded_error" || type === "rate_limit_error"
        ? "ai_busy"
        : type === "billing_error" || /credit|balance/i.test(JSON.stringify(data))
        ? "ai_no_credit"
        : "ai_error";
      return reply({ error: code, conversation_id: prep.conversation_id }, 502);
    }
    const text = ((data.content as Json[] | undefined) ?? [])
      .filter((b) => b.type === "text").map((b) => String(b.text)).join("").trim();
    const usage = (data.usage ?? {}) as Json;
    const tin = Number(usage.input_tokens ?? 0);
    const tout = Number(usage.output_tokens ?? 0);
    const cost = tin * PRICE_IN + tout * PRICE_OUT;

    let content = text;
    let flagged = false;
    if (content.startsWith(FLAG)) {
      flagged = true;
      content = content.slice(FLAG.length).trim();
    }
    const feedback = kind === "feedback" ? parseFeedback(text) : null;

    // 3) save with the secret key
    const fin = await rpc(fetcher, url, "ai_finish", {
      p_conversation: prep.conversation_id,
      p_role: kind === "feedback" ? "feedback" : "assistant",
      p_content: kind === "feedback" ? "" : content,
      p_in: tin,
      p_out: tout,
      p_cost: Number(cost.toFixed(6)),
      p_flagged: flagged,
      p_feedback: feedback,
    }, { apikey: k.secret, ...(k.secret.startsWith("sb_") ? {} : { Authorization: `Bearer ${k.secret}` }) }) as Json;

    return reply({
      conversation_id: prep.conversation_id,
      ...(feedback ? { feedback } : { reply: content || "…" }),
      flagged,
      remaining_today: fin?.remaining_today ?? prep.remaining_today - 1,
    });
  } catch (e) {
    if (e instanceof GatewayError) {
      const status = e.code === "not_found" ? 404 : e.status >= 500 ? 502 : 400;
      return reply({ error: e.code }, status);
    }
    console.error("ai-chat failed", e);
    return reply({ error: "ai_error" }, 500);
  }
}

// Supabase runtime entry point (the tests set AI_CHAT_TEST=1 and call handle() directly).
if (!Deno.env.get("AI_CHAT_TEST")) {
  Deno.serve((req) => handle(req, (n) => Deno.env.get(n)));
}
