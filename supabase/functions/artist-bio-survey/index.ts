// Supabase Edge Function: artist-bio-survey
// Purpose: Receive survey submissions, validate payload, persist to
//          public.artist_bio_surveys, and rate-limit by IP hash.
// Method:  POST
// Auth:    public (verify_jwt=false). RLS on the table blocks public reads;
//          service_role inserts via this function with payload validation.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { crypto } from "https://deno.land/std@0.224.0/crypto/mod.ts";

// HTML form inlined at build time (2026-07-11 deploy hook) — see artist-bio-survey.html for source.
const formHtml: string = "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"UTF-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n<meta name=\"description\" content=\"LOUDmusic In-Depth Artist Bio Survey \u2014 25 questions to craft a top-tier publicist-grade artist biography.\">\n<title>LOUDmusic \u2014 Artist Bio Survey</title>\n<link rel=\"preconnect\" href=\"https://fonts.googleapis.com\">\n<link rel=\"preconnect\" href=\"https://fonts.gstatic.com\" crossorigin>\n<link href=\"https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700;800;900&family=Space+Grotesk:wght@500;600;700&display=swap\" rel=\"stylesheet\">\n<style>\n  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }\n  :root {\n    --bg: #0A0A0A;\n    --surface: #131316;\n    --surface-2: #1C1C22;\n    --border: #2A2A33;\n    --border-focus: #00E5FF;\n    --text: #FFFFFF;\n    --text-muted: #9A9AA8;\n    --text-dim: #6B6B7B;\n    --accent: #00E5FF;\n    --accent-glow: rgba(0, 229, 255, 0.18);\n    --gold: #FFD24A;\n    --danger: #FF4D6D;\n    --success: #4ADE80;\n  }\n  html, body { height: 100%; }\n  body {\n    background: var(--bg);\n    color: var(--text);\n    font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;\n    font-size: 16px;\n    line-height: 1.6;\n    -webkit-font-smoothing: antialiased;\n    background-image:\n      radial-gradient(ellipse 1200px 600px at 50% -200px, rgba(0, 229, 255, 0.08), transparent),\n      radial-gradient(ellipse 800px 400px at 100% 100%, rgba(255, 210, 74, 0.04), transparent);\n    background-attachment: fixed;\n  }\n  .container { max-width: 760px; margin: 0 auto; padding: 32px 20px 80px; }\n\n  /* Header */\n  .header { text-align: center; padding: 40px 0 48px; }\n  .brand {\n    font-family: 'Space Grotesk', sans-serif;\n    font-weight: 700;\n    font-size: 13px;\n    letter-spacing: 0.32em;\n    color: var(--accent);\n    text-transform: uppercase;\n    margin-bottom: 28px;\n    display: inline-flex;\n    align-items: center;\n    gap: 10px;\n  }\n  .brand-dot {\n    width: 8px; height: 8px; border-radius: 50%;\n    background: var(--accent);\n    box-shadow: 0 0 12px var(--accent);\n    animation: pulse 2.4s ease-in-out infinite;\n  }\n  @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }\n  h1 {\n    font-family: 'Space Grotesk', sans-serif;\n    font-size: clamp(2rem, 5vw, 3rem);\n    font-weight: 700;\n    line-height: 1.1;\n    letter-spacing: -0.02em;\n    margin-bottom: 16px;\n  }\n  h1 .accent { color: var(--accent); }\n  .subtitle {\n    color: var(--text-muted);\n    font-size: 1.0625rem;\n    max-width: 560px;\n    margin: 0 auto;\n  }\n\n  /* Progress */\n  .progress-wrap {\n    position: sticky;\n    top: 0;\n    z-index: 10;\n    background: rgba(10, 10, 10, 0.85);\n    backdrop-filter: blur(12px);\n    -webkit-backdrop-filter: blur(12px);\n    padding: 16px 0;\n    margin: 0 -20px 32px;\n    padding-left: 20px;\n    padding-right: 20px;\n    border-bottom: 1px solid var(--border);\n  }\n  .progress-meta {\n    display: flex; justify-content: space-between; align-items: center;\n    margin-bottom: 8px;\n    font-size: 13px;\n    color: var(--text-muted);\n    font-weight: 500;\n  }\n  .progress-meta strong { color: var(--text); font-weight: 600; }\n  .progress-bar {\n    height: 4px;\n    background: var(--surface-2);\n    border-radius: 2px;\n    overflow: hidden;\n  }\n  .progress-fill {\n    height: 100%;\n    background: linear-gradient(90deg, var(--accent), var(--gold));\n    width: 0%;\n    transition: width 0.4s cubic-bezier(0.16, 1, 0.3, 1);\n    border-radius: 2px;\n  }\n\n  .step-chips {\n    display: grid;\n    grid-template-columns: repeat(7, minmax(0, 1fr));\n    gap: 6px;\n    margin-top: 12px;\n  }\n  .step-chip {\n    height: 4px;\n    border-radius: 999px;\n    background: var(--surface-2);\n    border: 1px solid rgba(255,255,255,0.04);\n  }\n  .step-chip.active { background: var(--accent); box-shadow: 0 0 16px var(--accent-glow); }\n  .step-chip.done { background: rgba(209, 168, 92, 0.65); }\n\n  .conversation-card {\n    background: linear-gradient(135deg, rgba(46, 229, 157, 0.10), rgba(209, 168, 92, 0.08));\n    border: 1px solid rgba(46, 229, 157, 0.18);\n    border-radius: 16px;\n    padding: 22px;\n    margin-bottom: 20px;\n  }\n  .conversation-eyebrow {\n    color: var(--accent);\n    font-family: 'Space Grotesk', sans-serif;\n    font-size: 0.75rem;\n    font-weight: 700;\n    letter-spacing: 0.16em;\n    text-transform: uppercase;\n    margin-bottom: 8px;\n  }\n  .conversation-prompt {\n    color: var(--text);\n    font-size: 1.05rem;\n    line-height: 1.7;\n    margin: 0;\n  }\n\n\n  /* Section */\n  .section {\n    display: none;\n    background: var(--surface);\n    border: 1px solid var(--border);\n    border-radius: 16px;\n    padding: 32px;\n    margin-bottom: 20px;\n    scroll-margin-top: 100px;\n    animation: sectionIn 0.22s ease-out;\n  }\n  .section.active { display: block; }\n  @keyframes sectionIn {\n    from { opacity: 0; transform: translateY(10px); }\n    to { opacity: 1; transform: translateY(0); }\n  }\n  .section-num {\n    font-family: 'Space Grotesk', sans-serif;\n    font-size: 13px;\n    font-weight: 600;\n    color: var(--accent);\n    letter-spacing: 0.18em;\n    text-transform: uppercase;\n    margin-bottom: 8px;\n  }\n  .section-title {\n    font-family: 'Space Grotesk', sans-serif;\n    font-size: 1.5rem;\n    font-weight: 700;\n    margin-bottom: 8px;\n    letter-spacing: -0.01em;\n  }\n  .section-intro {\n    color: var(--text-muted);\n    font-size: 0.9375rem;\n    margin-bottom: 24px;\n    padding-bottom: 20px;\n    border-bottom: 1px solid var(--border);\n  }\n\n  /* Form fields */\n  .field { margin-bottom: 24px; }\n  .field:last-child { margin-bottom: 0; }\n  .label {\n    display: flex;\n    align-items: baseline;\n    gap: 8px;\n    font-weight: 500;\n    font-size: 0.9375rem;\n    margin-bottom: 8px;\n    color: var(--text);\n  }\n  .q-num {\n    color: var(--accent);\n    font-family: 'Space Grotesk', sans-serif;\n    font-weight: 600;\n    font-size: 0.875rem;\n    flex-shrink: 0;\n  }\n  .help {\n    color: var(--text-dim);\n    font-size: 0.8125rem;\n    margin-top: 6px;\n  }\n  input[type=\"text\"],\n  input[type=\"date\"],\n  textarea {\n    width: 100%;\n    background: var(--surface-2);\n    border: 1px solid var(--border);\n    border-radius: 10px;\n    padding: 12px 14px;\n    color: var(--text);\n    font-family: inherit;\n    font-size: 0.9375rem;\n    line-height: 1.5;\n    transition: border-color 0.15s, box-shadow 0.15s, background 0.15s;\n  }\n  textarea { min-height: 96px; resize: vertical; }\n  input[type=\"text\"]:focus,\n  input[type=\"date\"]:focus,\n  textarea:focus {\n    outline: none;\n    border-color: var(--border-focus);\n    box-shadow: 0 0 0 3px var(--accent-glow);\n    background: #1F1F26;\n  }\n  input::placeholder, textarea::placeholder {\n    color: var(--text-dim);\n  }\n\n  /* Artist basics block */\n  .basics-grid {\n    display: grid;\n    grid-template-columns: 1fr 1fr;\n    gap: 16px;\n  }\n  @media (max-width: 600px) {\n    .basics-grid { grid-template-columns: 1fr; }\n    .section { padding: 24px 20px; }\n    .step-chips { grid-template-columns: repeat(7, 1fr); }\n    .actions { justify-content: stretch; }\n    .actions .btn { flex: 1 1 100%; justify-content: center; }\n  }\n\n  /* Submit / actions */\n  .actions {\n    display: flex;\n    flex-wrap: wrap;\n    gap: 12px;\n    justify-content: space-between;\n    align-items: center;\n    margin-top: 8px;\n    padding-top: 24px;\n    border-top: 1px solid var(--border);\n  }\n  .actions-left, .actions-right { display: flex; flex-wrap: wrap; gap: 12px; }\n  .btn {\n    font-family: 'Inter', sans-serif;\n    font-weight: 600;\n    font-size: 0.9375rem;\n    padding: 12px 24px;\n    border-radius: 10px;\n    border: 1px solid transparent;\n    cursor: pointer;\n    transition: all 0.15s;\n    display: inline-flex;\n    align-items: center;\n    gap: 8px;\n  }\n  .btn-primary {\n    background: var(--accent);\n    color: #001216;\n    box-shadow: 0 0 0 0 var(--accent-glow);\n  }\n  .btn-primary:hover {\n    transform: translateY(-1px);\n    box-shadow: 0 8px 24px var(--accent-glow);\n  }\n  .btn-primary:disabled {\n    opacity: 0.5;\n    cursor: not-allowed;\n    transform: none;\n    box-shadow: none;\n  }\n  .btn-ghost {\n    background: transparent;\n    color: var(--text-muted);\n    border-color: var(--border);\n  }\n  .btn-ghost:hover { color: var(--text); border-color: var(--text-muted); }\n\n  /* Success card */\n  .success {\n    display: none;\n    background: var(--surface);\n    border: 1px solid var(--border);\n    border-radius: 16px;\n    padding: 32px;\n    margin-top: 24px;\n  }\n  .success.show { display: block; }\n  .success-icon {\n    width: 56px; height: 56px;\n    background: rgba(74, 222, 128, 0.12);\n    color: var(--success);\n    border-radius: 50%;\n    display: flex; align-items: center; justify-content: center;\n    font-size: 28px;\n    margin-bottom: 16px;\n  }\n  .success h2 {\n    font-family: 'Space Grotesk', sans-serif;\n    font-size: 1.5rem;\n    margin-bottom: 8px;\n  }\n  .success p { color: var(--text-muted); margin-bottom: 20px; }\n  .bio-output,\n  .qa-output {\n    background: #050507;\n    border: 1px solid var(--border);\n    border-radius: 10px;\n    padding: 16px;\n    font-family: 'JetBrains Mono', 'SF Mono', Consolas, monospace;\n    font-size: 0.8125rem;\n    line-height: 1.7;\n    color: var(--text);\n    white-space: pre-wrap;\n    word-wrap: break-word;\n    max-height: 520px;\n    overflow-y: auto;\n    margin-bottom: 16px;\n  }\n  .next-steps {\n    background: var(--surface-2);\n    border-left: 3px solid var(--gold);\n    border-radius: 0 10px 10px 0;\n    padding: 16px 20px;\n    margin-top: 16px;\n  }\n  .next-steps h3 {\n    font-family: 'Space Grotesk', sans-serif;\n    font-size: 0.9375rem;\n    margin-bottom: 8px;\n    color: var(--gold);\n  }\n  .next-steps ol { padding-left: 20px; color: var(--text-muted); font-size: 0.875rem; }\n  .next-steps li { margin-bottom: 6px; }\n  .next-steps strong { color: var(--text); font-weight: 600; }\n  .qa-details summary { cursor: pointer; color: var(--gold); font-weight: 700; margin-bottom: 12px; }\n  .bio-output { border-left: 3px solid var(--accent); }\n\n  .review-grid {\n    display: grid;\n    gap: 12px;\n  }\n  .review-item {\n    background: var(--surface-2);\n    border: 1px solid var(--border);\n    border-radius: 10px;\n    padding: 12px 14px;\n  }\n  .review-label {\n    display: block;\n    color: var(--text-dim);\n    font-size: 0.75rem;\n    letter-spacing: 0.08em;\n    text-transform: uppercase;\n    margin-bottom: 4px;\n  }\n  .review-value { color: var(--text); line-height: 1.5; }\n  .review-note { color: var(--text-muted); margin-top: 16px; line-height: 1.7; }\n\n  /* Toast */\n  .toast {\n    position: fixed;\n    bottom: 24px;\n    left: 50%;\n    transform: translateX(-50%) translateY(20px);\n    background: var(--surface-2);\n    border: 1px solid var(--border);\n    color: var(--text);\n    padding: 12px 20px;\n    border-radius: 10px;\n    font-size: 0.875rem;\n    font-weight: 500;\n    opacity: 0;\n    transition: all 0.2s;\n    pointer-events: none;\n    z-index: 100;\n  }\n  .toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }\n\n  /* Loading spinner */\n  .spinner {\n    display: inline-block;\n    width: 14px; height: 14px;\n    border: 2px solid rgba(0, 18, 22, 0.3);\n    border-top-color: #001216;\n    border-radius: 50%;\n    animation: spin 0.8s linear infinite;\n  }\n  @keyframes spin { to { transform: rotate(360deg); } }\n\n  /* Footer */\n  .footer {\n    text-align: center;\n    color: var(--text-dim);\n    font-size: 0.8125rem;\n    margin-top: 48px;\n    padding-top: 24px;\n    border-top: 1px solid var(--border);\n  }\n  .footer a { color: var(--text-muted); text-decoration: none; }\n  .footer a:hover { color: var(--accent); }\n\n  /* Optional tag */\n  .opt {\n    font-size: 0.6875rem;\n    color: var(--text-dim);\n    font-weight: 400;\n    text-transform: uppercase;\n    letter-spacing: 0.08em;\n    background: var(--surface-2);\n    padding: 2px 8px;\n    border-radius: 4px;\n  }\n</style>\n</head>\n<body>\n  <div class=\"container\">\n    <header class=\"header\">\n      <div class=\"brand\">\n        <span class=\"brand-dot\"></span>\n        LOUDmusic\n      </div>\n      <h1>Artist <span class=\"accent\">Bio</span> Survey</h1>\n      <p class=\"subtitle\">A guided artist interview \u2014 one focused step at a time. Answer naturally, and we\u2019ll turn the raw story into a publicist-grade bio.</p>\n    </header>\n\n    <div class=\"progress-wrap\" id=\"progressWrap\">\n      <div class=\"progress-meta\">\n        <span>Step <strong id=\"stepCurrent\">1</strong> of <strong id=\"stepTotal\">7</strong> \u00b7 <strong id=\"progressCount\">0</strong> answered</span>\n        <span id=\"progressPct\">0%</span>\n      </div>\n      <div class=\"progress-bar\"><div class=\"progress-fill\" id=\"progressFill\"></div></div>\n      <div class=\"step-chips\" id=\"stepChips\" aria-label=\"Survey steps\"></div>\n    </div>\n\n    <form id=\"bioForm\" novalidate>\n      <div class=\"conversation-card\" aria-live=\"polite\">\n        <div class=\"conversation-eyebrow\" id=\"stepEyebrow\">Quick setup</div>\n        <p class=\"conversation-prompt\" id=\"stepPrompt\">First, tell us who you are and where to send the finished bio. Then we\u2019ll move through your story one piece at a time.</p>\n      </div>\n\n      <!-- Quick-start: name + email so we can route back to the artist -->\n      <div class=\"section\">\n        <div class=\"section-num\">Setup</div>\n        <h2 class=\"section-title\">Let's start with you</h2>\n        <p class=\"section-intro\">A few basics so we can route your bio back to you. Your email is never shared publicly.</p>\n\n        <div class=\"basics-grid\">\n          <div class=\"field\">\n            <label class=\"label\" for=\"artist_name\"><span class=\"q-num\">\u2605</span>Stage / artist name</label>\n            <input type=\"text\" id=\"artist_name\" name=\"artist_name\" placeholder=\"e.g. Avery Cole\" required>\n          </div>\n          <div class=\"field\">\n            <label class=\"label\" for=\"artist_email\"><span class=\"q-num\">\u2605</span>Email</label>\n            <input type=\"text\" id=\"artist_email\" name=\"artist_email\" placeholder=\"you@domain.com\" required>\n          </div>\n          <div class=\"field\">\n            <label class=\"label\" for=\"artist_pronouns\"><span class=\"q-num\">\u2605</span>Pronouns</label>\n            <select id=\"artist_pronouns\" name=\"artist_pronouns\" required style=\"width:100%;background:var(--surface-2);border:1px solid var(--border);border-radius:10px;padding:12px 14px;color:var(--text);font-family:inherit;font-size:0.9375rem;appearance:none;background-image:url('data:image/svg+xml;utf8,<svg xmlns=%22http://www.w3.org/2000/svg%22 width=%2212%22 height=%2212%22 viewBox=%220 0 12 12%22><path fill=%22%239A9AA8%22 d=%22M6 9L1 4h10z%22/></svg>');background-repeat:no-repeat;background-position:right 14px center;background-size:12px;\">\n              <option value=\"\">\u2014 select \u2014</option>\n              <option value=\"he/him\">he / him</option>\n              <option value=\"she/her\">she / her</option>\n              <option value=\"they/them\">they / them</option>\n              <option value=\"custom\">Custom (type below)</option>\n            </select>\n            <input type=\"text\" id=\"artist_pronouns_custom\" name=\"artist_pronouns_custom\" placeholder=\"e.g. xe / xem\" style=\"margin-top:8px;display:none;\">\n          </div>\n          <div class=\"field\">\n            <label class=\"label\" for=\"artist_phone\">Phone <span class=\"opt\">Optional</span></label>\n            <input type=\"text\" id=\"artist_phone\" name=\"artist_phone\" placeholder=\"(555) 555-5555\">\n          </div>\n          <div class=\"field\">\n            <label class=\"label\" for=\"artist_social\">Primary social handle <span class=\"opt\">Optional</span></label>\n            <input type=\"text\" id=\"artist_social\" name=\"artist_social\" placeholder=\"@yourhandle on IG / TikTok / X\">\n          </div>\n          <div class=\"field\">\n            <label class=\"label\" for=\"current_city\">Current city / base <span class=\"opt\">Optional</span></label>\n            <input type=\"text\" id=\"current_city\" name=\"current_city\" placeholder=\"e.g. Atlanta, GA\">\n          </div>\n        </div>\n      </div>\n\n      <!-- Section 1 -->\n      <div class=\"section\">\n        <div class=\"section-num\">Section 01 / 05</div>\n        <h2 class=\"section-title\">Early Life &amp; Beginnings</h2>\n        <p class=\"section-intro\">Where the story starts. Be specific \u2014 dates, places, the song that changed everything.</p>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q1\"><span class=\"q-num\">01</span>Where and when were you born?</label>\n          <input type=\"text\" id=\"q1\" name=\"q1_birthplace_birthdate\" placeholder=\"City, State / Country \u00b7 Month YYYY\" required>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q2\"><span class=\"q-num\">02</span>When did you first discover your love for music?</label>\n          <textarea id=\"q2\" name=\"q2_love_for_music\" placeholder=\"Age, moment, environment...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q3\"><span class=\"q-num\">03</span>What kind of music did you grow up listening to?</label>\n          <textarea id=\"q3\" name=\"q3_grow_up_listening\" placeholder=\"Genres, artists, household soundtrack...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q4\"><span class=\"q-num\">04</span>Were there any family members or friends who influenced your musical journey?</label>\n          <textarea id=\"q4\" name=\"q4_influencers\" placeholder=\"A parent who played bass, a cousin who introduced you to hip-hop...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q5\"><span class=\"q-num\">05</span>Do you remember the first instrument you played or the first song you sang?</label>\n          <textarea id=\"q5\" name=\"q5_first_instrument_song\" placeholder=\"First guitar chord, first stage, first song you ever wrote...\" required></textarea>\n        </div>\n      </div>\n\n      <!-- Section 2 -->\n      <div class=\"section\">\n        <div class=\"section-num\">Section 02 / 05</div>\n        <h2 class=\"section-title\">Education &amp; Training</h2>\n        <p class=\"section-intro\">The reps you put in. Formal or self-taught \u2014 both count, both shape the artist.</p>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q6\"><span class=\"q-num\">06</span>Did you receive any formal musical training or education?</label>\n          <textarea id=\"q6\" name=\"q6_formal_training\" placeholder=\"School, conservatory, online courses, mentor...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q7\"><span class=\"q-num\">07</span>Were there any mentors, teachers, or role models who shaped your musical path?</label>\n          <textarea id=\"q7\" name=\"q7_mentors\" placeholder=\"Names, what they taught you, lasting impact...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q8\"><span class=\"q-num\">08</span>What was the most valuable lesson you learned about music early on?</label>\n          <textarea id=\"q8\" name=\"q8_early_lesson\" placeholder=\"A principle you still carry...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q9\"><span class=\"q-num\">09</span>How did your educational background influence your approach to music?</label>\n          <textarea id=\"q9\" name=\"q9_education_influence\" placeholder=\"In-classical-training, self-taught, business degree applied to A&amp;R...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q10\"><span class=\"q-num\">10</span>Did you participate in school bands, choirs, or other musical activities?</label>\n          <textarea id=\"q10\" name=\"q10_school_activities\" placeholder=\"Marching band, jazz band, gospel choir, battle of the bands...\" required></textarea>\n        </div>\n      </div>\n\n      <!-- Section 3 -->\n      <div class=\"section\">\n        <div class=\"section-num\">Section 03 / 05</div>\n        <h2 class=\"section-title\">Career &amp; Achievements</h2>\n        <p class=\"section-intro\">Proof of movement. Even if it's early \u2014 releases, sessions, opens, press, milestones.</p>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q11\"><span class=\"q-num\">11</span>What inspired you to pursue music as a career?</label>\n          <textarea id=\"q11\" name=\"q11_pursue_music\" placeholder=\"The decision point. What tipped it from hobby to calling.\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q12\"><span class=\"q-num\">12</span>Can you describe your first major break or performance?</label>\n          <textarea id=\"q12\" name=\"q12_first_break\" placeholder=\"The venue, the moment, who was in the room...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q13\"><span class=\"q-num\">13</span>What has been the most challenging aspect of building your music career?</label>\n          <textarea id=\"q13\" name=\"q13_challenges\" placeholder=\"Be honest \u2014 the bio can reframe this as grit.\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q14\"><span class=\"q-num\">14</span>Which of your songs or projects are you most proud of, and why?</label>\n          <textarea id=\"q14\" name=\"q14_proudest_work\" placeholder=\"Title, year, what it represents...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q15\"><span class=\"q-num\">15</span>Have you won any awards or received notable recognition for your work?</label>\n          <textarea id=\"q15\" name=\"q15_awards_recognition\" placeholder=\"Awards, press features, playlist adds, sync placements, label co-signs...\" required></textarea>\n        </div>\n      </div>\n\n      <!-- Section 4 -->\n      <div class=\"section\">\n        <div class=\"section-num\">Section 04 / 05</div>\n        <h2 class=\"section-title\">Creative Process &amp; Influences</h2>\n        <p class=\"section-intro\">The sonic fingerprint. This is where the publicist extracts the texture for the bio.</p>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q16\"><span class=\"q-num\">16</span>How would you describe your style or genre of music?</label>\n          <textarea id=\"q16\" name=\"q16_style_genre\" placeholder=\"Don't be modest. Be precise. 'Detroit house meets Southern trap cadence' beats 'eclectic.'\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q17\"><span class=\"q-num\">17</span>Who are your biggest musical inspirations, past or present?</label>\n          <textarea id=\"q17\" name=\"q17_inspirations\" placeholder=\"Artists, producers, eras, specific records...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q18\"><span class=\"q-num\">18</span>What's your creative process like when writing songs or composing music?</label>\n          <textarea id=\"q18\" name=\"q18_creative_process\" placeholder=\"Rituals, time of day, sessions vs. solo, gear...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q19\"><span class=\"q-num\">19</span>Are there any specific themes or messages you aim to convey through your music?</label>\n          <textarea id=\"q19\" name=\"q19_themes_messages\" placeholder=\"The 'why' behind the writing...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q20\"><span class=\"q-num\">20</span>How has your music evolved over the years?</label>\n          <textarea id=\"q20\" name=\"q20_evolution\" placeholder=\"The arc. Where you started vs. where you are now.\" required></textarea>\n        </div>\n      </div>\n\n      <!-- Section 5 -->\n      <div class=\"section\">\n        <div class=\"section-num\">Section 05 / 05</div>\n        <h2 class=\"section-title\">Personal &amp; Public Life</h2>\n        <p class=\"section-intro\">The human behind the music. The things that make a journalist pick up the phone.</p>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q21\"><span class=\"q-num\">21</span>How do you balance your personal life with your music career?</label>\n          <textarea id=\"q21\" name=\"q21_balance\" placeholder=\"Family, day job, side projects, the tradeoffs...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q22\"><span class=\"q-num\">22</span>Are there causes or charities that are particularly important to you as an artist?</label>\n          <textarea id=\"q22\" name=\"q22_causes\" placeholder=\"Mental health, equity, education, community work...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q23\"><span class=\"q-num\">23</span>What has been the most memorable moment of connecting with your fans?</label>\n          <textarea id=\"q23\" name=\"q23_fan_moment\" placeholder=\"A DM, a show, a story someone shared...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q24\"><span class=\"q-num\">24</span>How do you stay inspired and motivated to create new music?</label>\n          <textarea id=\"q24\" name=\"q24_inspiration\" placeholder=\"Inputs, rituals, what pulls you back to the studio...\" required></textarea>\n        </div>\n\n        <div class=\"field\">\n          <label class=\"label\" for=\"q25\"><span class=\"q-num\">25</span>What legacy do you hope to leave in the music world?</label>\n          <textarea id=\"q25\" name=\"q25_legacy\" placeholder=\"The long view. What do you want to be remembered for?\" required></textarea>\n        </div>\n      </div>\n\n      <!-- Review step -->\n      <div class=\"section review-section\" id=\"reviewStep\">\n        <div class=\"section-num\">Final Step</div>\n        <h2 class=\"section-title\">Review &amp; submit</h2>\n        <p class=\"section-intro\">You made it. Give the essentials one last look, then submit your answers and we\u2019ll generate the finished bio with the Architect Publicist.</p>\n        <div class=\"review-grid\" id=\"reviewOutput\"></div>\n        <p class=\"review-note\">After submission, the publicist agent will write the full bio kit automatically. The raw Q&amp;A will still be available underneath for reference.</p>\n      </div>\n\n      <div class=\"actions\" id=\"stepActions\">\n        <div class=\"actions-left\">\n          <button type=\"button\" class=\"btn btn-ghost\" id=\"prevStep\">\u2190 Back</button>\n          <button type=\"button\" class=\"btn btn-ghost\" id=\"saveDraft\">Save progress locally</button>\n        </div>\n        <div class=\"actions-right\">\n          <button type=\"button\" class=\"btn btn-primary\" id=\"nextStep\">Next \u2192</button>\n          <button type=\"submit\" class=\"btn btn-primary\" id=\"submitBtn\">Generate my bio \u2192</button>\n        </div>\n      </div>\n    </form>\n\n    <!-- Success card with generated bio + Q&A output -->\n    <div class=\"success\" id=\"successCard\">\n      <div class=\"success-icon\">\u2713</div>\n      <h2>Your artist bio is ready.</h2>\n      <p>Your responses were submitted to LOUDmusic and the Architect Publicist generated a finished bio kit below.</p>\n\n      <div class=\"bio-output\" id=\"bioOutput\"></div>\n\n      <div class=\"actions\" style=\"border-top: none; padding-top: 0; margin-top: 0;\">\n        <button type=\"button\" class=\"btn btn-primary\" id=\"copyBio\">Copy Bio</button>\n        <button type=\"button\" class=\"btn btn-ghost\" id=\"downloadBio\">Download Bio .txt</button>\n      </div>\n\n      <details class=\"next-steps qa-details\">\n        <summary>Raw survey Q&amp;A</summary>\n        <div class=\"qa-output\" id=\"qaOutput\"></div>\n        <div class=\"actions\" style=\"border-top: none; padding-top: 0; margin-top: 12px;\">\n          <button type=\"button\" class=\"btn btn-ghost\" id=\"copyQa\">Copy Q&amp;A</button>\n          <button type=\"button\" class=\"btn btn-ghost\" id=\"downloadQa\">Download Q&amp;A .txt</button>\n        </div>\n      </details>\n    </div>\n\n    <footer class=\"footer\">\n      Powered by <a href=\"https://loudmusic.io\" target=\"_blank\" rel=\"noopener\">LOUDmusic</a> \u00b7 Survey responses are stored securely and used only to draft your artist bio.\n    </footer>\n  </div>\n\n  <div class=\"toast\" id=\"toast\"></div>\n\n<script>\n(function() {\n  'use strict';\n\n  // -------- Configuration --------\n  // Default: post to the LOUDmusic artist-bio-survey Supabase Edge Function.\n  // To override (testing), set window.__BIO_FORM_ENDPOINT__ before this script runs.\n  const DEFAULT_ENDPOINT = 'https://hupiguhcsmeucownlbre.supabase.co/functions/v1/artist-bio-survey';\n  const ENDPOINT = (window.__BIO_FORM_ENDPOINT__ || DEFAULT_ENDPOINT).replace(/\\/+$/, '');\n\n  // Supabase publishable key (sb_publishable_...). Safe to ship in client HTML \u2014\n  // RLS + Edge Function payload shape enforce server-side access control.\n  const ANON_KEY = 'sb_publishable_G7zOAJMBjLxij-FLTTlgtw_wnAkT0_F';\n\n  // -------- Elements --------\n  const form = document.getElementById('bioForm');\n  const submitBtn = document.getElementById('submitBtn');\n  const nextStepBtn = document.getElementById('nextStep');\n  const prevStepBtn = document.getElementById('prevStep');\n  const saveDraftBtn = document.getElementById('saveDraft');\n  const progressCount = document.getElementById('progressCount');\n  const progressPct = document.getElementById('progressPct');\n  const progressFill = document.getElementById('progressFill');\n  const stepCurrent = document.getElementById('stepCurrent');\n  const stepTotal = document.getElementById('stepTotal');\n  const stepChips = document.getElementById('stepChips');\n  const stepEyebrow = document.getElementById('stepEyebrow');\n  const stepPrompt = document.getElementById('stepPrompt');\n  const reviewOutput = document.getElementById('reviewOutput');\n  const successCard = document.getElementById('successCard');\n  const bioOutput = document.getElementById('bioOutput');\n  const qaOutput = document.getElementById('qaOutput');\n  const copyBioBtn = document.getElementById('copyBio');\n  const downloadBioBtn = document.getElementById('downloadBio');\n  const copyQaBtn = document.getElementById('copyQa');\n  const downloadQaBtn = document.getElementById('downloadQa');\n  const toast = document.getElementById('toast');\n  const sections = Array.from(form.querySelectorAll('.section'));\n  let currentStep = 0;\n  const STEP_COPY = [\n    ['Quick setup', 'First, tell us who you are and where to send the finished bio. Then we\u2019ll move through your story one piece at a time.'],\n    ['Chapter 1', 'Let\u2019s start at the beginning. Don\u2019t worry about sounding polished \u2014 details, places, and first memories are what make this useful.'],\n    ['Chapter 2', 'Now give us the training, mentors, and lessons that shaped your ear. Formal school counts. Self-taught reps count too.'],\n    ['Chapter 3', 'This is the movement section: releases, moments, proof, setbacks, and the wins that show your trajectory.'],\n    ['Chapter 4', 'Now we get to the sound. Be specific about texture, influences, process, and the emotional world of the music.'],\n    ['Chapter 5', 'Last story section: the person behind the records, the values, fan connection, and the legacy you want to build.'],\n    ['Final check', 'Review the essentials. If everything looks right, submit and the form will generate your finished bio kit.'],\n  ];\n\n  // -------- 25 question labels (in order) --------\n  const Q_LABELS = [\n    ['q1_birthplace_birthdate',  'Where and when were you born?'],\n    ['q2_love_for_music',        'When did you first discover your love for music?'],\n    ['q3_grow_up_listening',     'What kind of music did you grow up listening to?'],\n    ['q4_influencers',           'Family members or friends who influenced your musical journey?'],\n    ['q5_first_instrument_song', 'First instrument you played or first song you sang?'],\n    ['q6_formal_training',       'Did you receive any formal musical training or education?'],\n    ['q7_mentors',               'Mentors, teachers, or role models who shaped your musical path?'],\n    ['q8_early_lesson',          'Most valuable lesson you learned about music early on?'],\n    ['q9_education_influence',   'How did your educational background influence your approach to music?'],\n    ['q10_school_activities',    'Did you participate in school bands, choirs, or other musical activities?'],\n    ['q11_pursue_music',         'What inspired you to pursue music as a career?'],\n    ['q12_first_break',          'Can you describe your first major break or performance?'],\n    ['q13_challenges',           'Most challenging aspect of building your music career?'],\n    ['q14_proudest_work',        'Songs or projects you are most proud of, and why?'],\n    ['q15_awards_recognition',   'Awards or notable recognition for your work?'],\n    ['q16_style_genre',          'How would you describe your style or genre of music?'],\n    ['q17_inspirations',         'Biggest musical inspirations, past or present?'],\n    ['q18_creative_process',     'Creative process when writing songs or composing music?'],\n    ['q19_themes_messages',      'Specific themes or messages you aim to convey through your music?'],\n    ['q20_evolution',            'How has your music evolved over the years?'],\n    ['q21_balance',              'How do you balance your personal life with your music career?'],\n    ['q22_causes',               'Causes or charities important to you as an artist?'],\n    ['q23_fan_moment',           'Most memorable moment of connecting with your fans?'],\n    ['q24_inspiration',          'How do you stay inspired and motivated to create new music?'],\n    ['q25_legacy',               'What legacy do you hope to leave in the music world?'],\n  ];\n\n  // Pronouns dropdown \u2192 custom-input toggle\n  const pronounsSelect = document.getElementById('artist_pronouns');\n  const pronounsCustom = document.getElementById('artist_pronouns_custom');\n  if (pronounsSelect && pronounsCustom) {\n    pronounsSelect.addEventListener('change', function() {\n      if (pronounsSelect.value === 'custom') {\n        pronounsCustom.style.display = 'block';\n        pronounsCustom.required = true;\n        pronounsCustom.focus();\n      } else {\n        pronounsCustom.style.display = 'none';\n        pronounsCustom.required = false;\n        pronounsCustom.value = '';\n      }\n      updateProgress();\n    });\n  }\n\n  // -------- Helpers --------\n  function showToast(msg, ms = 2400) {\n    toast.textContent = msg;\n    toast.classList.add('show');\n    clearTimeout(showToast._t);\n    showToast._t = setTimeout(() => toast.classList.remove('show'), ms);\n  }\n\n  function getFormData() {\n    const fd = new FormData(form);\n    const data = {};\n    for (const [k, v] of fd.entries()) data[k] = (v || '').toString().trim();\n    // Resolve pronouns: if \"custom\" was selected, use the custom field\n    if (data.artist_pronouns === 'custom') {\n      data.pronouns = data.artist_pronouns_custom || '';\n    } else {\n      data.pronouns = data.artist_pronouns || '';\n    }\n    delete data.artist_pronouns_custom;\n    return data;\n  }\n\n  function answeredCount(data) {\n    let n = 0;\n    for (const [key] of Q_LABELS) {\n      if (data[key] && data[key].length > 0) n++;\n    }\n    if (data.artist_name) n++;\n    if (data.artist_email) n++;\n    if (data.pronouns) n++;\n    return n;\n  }\n\n  function totalCount() {\n    return Q_LABELS.length + 3; // +3 for name + email + pronouns\n  }\n\n  function updateProgress() {\n    const data = getFormData();\n    const c = answeredCount(data);\n    const t = totalCount();\n    const pct = Math.round((c / t) * 100);\n    progressCount.textContent = c;\n    progressPct.textContent = pct + '%';\n    progressFill.style.width = pct + '%';\n  }\n\n  function escapeHTML(value) {\n    return String(value || '').replace(/[&<>\"]/g, function(ch) {\n      return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '\"': '&quot;' })[ch];\n    });\n  }\n\n  function buildReview(data) {\n    const requiredAnswered = Q_LABELS.filter(([key]) => data[key]).length;\n    const items = [\n      ['Artist', data.artist_name],\n      ['Email', data.artist_email],\n      ['Pronouns', data.pronouns],\n      ['City / base', data.current_city || 'Not provided'],\n      ['Sonic identity', data.q16_style_genre || 'Not answered yet'],\n      ['Questions answered', requiredAnswered + ' of ' + Q_LABELS.length],\n    ];\n    reviewOutput.innerHTML = items.map(([label, value]) => `\n      <div class=\"review-item\">\n        <span class=\"review-label\">${escapeHTML(label)}</span>\n        <div class=\"review-value\">${escapeHTML(value)}</div>\n      </div>\n    `).join('');\n  }\n\n  function renderStep(shouldScroll = false) {\n    sections.forEach((section, idx) => {\n      section.classList.toggle('active', idx === currentStep);\n      section.setAttribute('aria-hidden', idx === currentStep ? 'false' : 'true');\n    });\n    const last = currentStep === sections.length - 1;\n    prevStepBtn.disabled = currentStep === 0;\n    nextStepBtn.style.display = last ? 'none' : 'inline-flex';\n    submitBtn.style.display = last ? 'inline-flex' : 'none';\n    stepCurrent.textContent = currentStep + 1;\n    stepTotal.textContent = sections.length;\n    const copy = STEP_COPY[currentStep] || STEP_COPY[0];\n    stepEyebrow.textContent = copy[0];\n    stepPrompt.textContent = copy[1];\n    stepChips.innerHTML = sections.map((_, idx) => `<span class=\"step-chip ${idx === currentStep ? 'active' : idx < currentStep ? 'done' : ''}\"></span>`).join('');\n    if (last) buildReview(getFormData());\n    updateProgress();\n    if (shouldScroll) {\n      document.querySelector('.progress-wrap').scrollIntoView({ behavior: 'smooth', block: 'start' });\n    }\n  }\n\n  function validateStep(stepIdx) {\n    const data = getFormData();\n    if (stepIdx === 0) {\n      if (!data.artist_name) { showToast('First, enter your stage / artist name.'); document.getElementById('artist_name').focus(); return false; }\n      if (!data.artist_email || !/^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$/.test(data.artist_email)) {\n        showToast('Enter a valid email so we can send the bio back.');\n        document.getElementById('artist_email').focus();\n        return false;\n      }\n      if (!data.pronouns) { showToast('Select your pronouns before moving on.'); document.getElementById('artist_pronouns').focus(); return false; }\n      return true;\n    }\n    const currentSection = sections[stepIdx];\n    const missing = currentSection && Array.from(currentSection.querySelectorAll('[required]')).find((el) => !String(el.value || '').trim());\n    if (missing) {\n      const q = missing.id && missing.id.startsWith('q') ? missing.id.replace('q', '') : '';\n      showToast(q ? 'Please answer question ' + q + ' before moving on.' : 'Please complete this step before moving on.');\n      missing.focus();\n      return false;\n    }\n    return true;\n  }\n\n  function buildQA(data) {\n    // Format: each Q&A as \"Question N\\nAnswer N\" per the user spec\n    const lines = [];\n    lines.push(`Artist Name: ${data.artist_name || ''}`);\n    lines.push(`Pronouns: ${data.pronouns || ''}`);\n    lines.push(`Email: ${data.artist_email || ''}`);\n    if (data.artist_phone) lines.push(`Phone: ${data.artist_phone}`);\n    if (data.artist_social) lines.push(`Primary Social: ${data.artist_social}`);\n    if (data.current_city) lines.push(`Current City: ${data.current_city}`);\n    lines.push('');\n    Q_LABELS.forEach(([key, label], idx) => {\n      lines.push(`Question ${idx + 1}`);\n      lines.push(label);\n      lines.push(`Answer ${idx + 1}`);\n      lines.push(data[key] || '');\n      lines.push('');\n    });\n    return lines.join('\\n').trim();\n  }\n\n  // -------- Local-storage draft persistence --------\n  const DRAFT_KEY = 'loudmusic_bio_survey_draft_v1';\n  function saveDraftLocal() {\n    const data = getFormData();\n    try {\n      localStorage.setItem(DRAFT_KEY, JSON.stringify({ ts: Date.now(), data }));\n      showToast('Progress saved to this browser.');\n    } catch (e) {\n      showToast('Could not save locally (storage full or blocked).');\n    }\n  }\n  function loadDraftLocal() {\n    try {\n      const raw = localStorage.getItem(DRAFT_KEY);\n      if (!raw) return;\n      const parsed = JSON.parse(raw);\n      if (!parsed || !parsed.data) return;\n      for (const [k, v] of Object.entries(parsed.data)) {\n        const el = form.elements[k];\n        if (el && typeof v === 'string') el.value = v;\n      }\n      if (pronounsSelect) pronounsSelect.dispatchEvent(new Event('change'));\n      updateProgress();\n    } catch (e) { /* ignore */ }\n  }\n  function clearDraftLocal() {\n    try { localStorage.removeItem(DRAFT_KEY); } catch (e) { /* ignore */ }\n  }\n\n  // -------- Submission --------\n  async function submitForm(data) {\n    submitBtn.disabled = true;\n    submitBtn.innerHTML = '<span class=\"spinner\"></span> Generating bio...';\n    try {\n      const res = await fetch(ENDPOINT, {\n        method: 'POST',\n        headers: {\n          'Content-Type': 'application/json',\n          'apikey': ANON_KEY,\n          'Authorization': 'Bearer ' + ANON_KEY,\n        },\n        body: JSON.stringify(data),\n      });\n      const text = await res.text();\n      let json = null;\n      try { json = text ? JSON.parse(text) : null; } catch (e) { /* non-JSON */ }\n      if (!res.ok) {\n        const msg = (json && (json.error || json.message)) || ('HTTP ' + res.status);\n        throw new Error(msg);\n      }\n      return { ok: true, response: json };\n    } finally {\n      submitBtn.disabled = false;\n      submitBtn.textContent = 'Generate my bio \u2192';\n    }\n  }\n\n  function showSuccess(data, response) {\n    const qa = (response && response.qa) || buildQA(data);\n    const bio = response && response.bio;\n    qaOutput.textContent = qa;\n    bioOutput.textContent = bio || 'Your survey was received, but the automated bio generator could not complete this run. Your raw Q&A is saved below for LOUDmusic to regenerate the bio.';\n    successCard.classList.add('show');\n    // Scroll the success card into view\n    setTimeout(() => {\n      successCard.scrollIntoView({ behavior: 'smooth', block: 'start' });\n    }, 50);\n  }\n\n  // -------- Events --------\n  form.addEventListener('input', function() {\n    updateProgress();\n    if (currentStep === sections.length - 1) buildReview(getFormData());\n  });\n  form.addEventListener('change', function() {\n    updateProgress();\n    if (currentStep === sections.length - 1) buildReview(getFormData());\n  });\n  saveDraftBtn.addEventListener('click', saveDraftLocal);\n  prevStepBtn.addEventListener('click', function() {\n    if (currentStep > 0) {\n      currentStep -= 1;\n      renderStep(true);\n    }\n  });\n  nextStepBtn.addEventListener('click', function() {\n    if (!validateStep(currentStep)) return;\n    if (currentStep < sections.length - 1) {\n      currentStep += 1;\n      renderStep(true);\n    }\n  });\n\n  form.addEventListener('submit', async function(ev) {\n    ev.preventDefault();\n    if (currentStep < sections.length - 1) {\n      if (validateStep(currentStep)) {\n        currentStep += 1;\n        renderStep(true);\n      }\n      return;\n    }\n    const data = getFormData();\n\n    // Basic validation\n    if (!data.artist_name) { showToast('Please enter your stage / artist name.'); document.getElementById('artist_name').focus(); return; }\n    if (!data.artist_email || !/^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$/.test(data.artist_email)) {\n      showToast('Please enter a valid email so we can reach you.');\n      document.getElementById('artist_email').focus();\n      return;\n    }\n    if (!data.pronouns) {\n      showToast('Please select your pronouns (or enter custom).');\n      document.getElementById('artist_pronouns').focus();\n      return;\n    }\n    if (data.pronouns === 'custom' && !data.artist_pronouns_custom) {\n      showToast('Please enter your custom pronouns.');\n      document.getElementById('artist_pronouns_custom').focus();\n      return;\n    }\n    const missingIdx = Q_LABELS.findIndex(([key]) => !data[key]);\n    if (missingIdx !== -1) {\n      showToast('Please answer question ' + (missingIdx + 1) + ' before submitting.');\n      const el = document.getElementById('q' + (missingIdx + 1));\n      if (el) {\n        el.focus();\n        el.closest('.section').scrollIntoView({ behavior: 'smooth', block: 'center' });\n      }\n      return;\n    }\n\n    try {\n      const result = await submitForm(data);\n      showSuccess(data, result.response);\n      clearDraftLocal();\n      showToast(result.response && result.response.bio ? 'Bio generated. Your bio kit is ready below.' : 'Survey received. Bio generation needs a retry.');\n    } catch (err) {\n      console.error('Submit failed', err);\n      // Even on backend failure, show the Q&A so the artist isn't blocked.\n      showSuccess(data, null);\n      showToast('Saved locally \u2014 could not reach the server. Your Q&A is below for recovery.');\n    }\n  });\n\n  copyBioBtn.addEventListener('click', async function() {\n    const text = bioOutput.textContent;\n    try {\n      await navigator.clipboard.writeText(text);\n      showToast('Bio copied to clipboard.');\n    } catch (e) {\n      const range = document.createRange();\n      range.selectNodeContents(bioOutput);\n      const sel = window.getSelection();\n      sel.removeAllRanges();\n      sel.addRange(range);\n      try {\n        document.execCommand('copy');\n        showToast('Bio copied.');\n      } catch (e2) {\n        showToast('Copy failed. Select the bio manually and press \u2318/Ctrl+C.');\n      }\n      sel.removeAllRanges();\n    }\n  });\n\n  downloadBioBtn.addEventListener('click', function() {\n    const text = bioOutput.textContent;\n    const name = (form.elements.artist_name.value || 'artist').replace(/[^a-z0-9_-]+/gi, '_');\n    const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });\n    const url = URL.createObjectURL(blob);\n    const a = document.createElement('a');\n    a.href = url;\n    a.download = name + '_artist_bio.txt';\n    document.body.appendChild(a);\n    a.click();\n    document.body.removeChild(a);\n    URL.revokeObjectURL(url);\n    showToast('Bio downloaded.');\n  });\n\n  copyQaBtn.addEventListener('click', async function() {\n    const text = qaOutput.textContent;\n    try {\n      await navigator.clipboard.writeText(text);\n      showToast('Q&A copied to clipboard.');\n    } catch (e) {\n      // Fallback: select the text in the pre block\n      const range = document.createRange();\n      range.selectNodeContents(qaOutput);\n      const sel = window.getSelection();\n      sel.removeAllRanges();\n      sel.addRange(range);\n      try {\n        document.execCommand('copy');\n        showToast('Q&A copied.');\n      } catch (e2) {\n        showToast('Copy failed. Select the text manually and press \u2318/Ctrl+C.');\n      }\n      sel.removeAllRanges();\n    }\n  });\n\n  downloadQaBtn.addEventListener('click', function() {\n    const text = qaOutput.textContent;\n    const name = (form.elements.artist_name.value || 'artist').replace(/[^a-z0-9_-]+/gi, '_');\n    const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });\n    const url = URL.createObjectURL(blob);\n    const a = document.createElement('a');\n    a.href = url;\n    a.download = name + '_bio_survey_QA.txt';\n    document.body.appendChild(a);\n    a.click();\n    document.body.removeChild(a);\n    URL.revokeObjectURL(url);\n    showToast('Q&A downloaded.');\n  });\n\n  // Initial load\n  loadDraftLocal();\n  renderStep(false);\n})();\n</script>\n</body>\n</html>\n";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const IP_SALT = Deno.env.get("BIO_SURVEY_IP_SALT") ?? "loudmusic";
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY") ?? "";
const OPENAI_MODEL = Deno.env.get("BIO_SURVEY_OPENAI_MODEL") ?? "gpt-4.1";
const OPENROUTER_API_KEY = Deno.env.get("OPENROUTER_API_KEY") ?? "";
const OPENROUTER_MODEL = Deno.env.get("BIO_SURVEY_OPENROUTER_MODEL") ?? "openai/gpt-4.1-mini";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey, x-client-info",
  "Access-Control-Max-Age": "86400",
};

const REQUIRED_FIELDS = [
  "artist_name", "pronouns", "artist_email",
  "q1_birthplace_birthdate", "q2_love_for_music", "q3_grow_up_listening",
  "q4_influencers", "q5_first_instrument_song",
  "q6_formal_training", "q7_mentors", "q8_early_lesson",
  "q9_education_influence", "q10_school_activities",
  "q11_pursue_music", "q12_first_break", "q13_challenges",
  "q14_proudest_work", "q15_awards_recognition",
  "q16_style_genre", "q17_inspirations", "q18_creative_process",
  "q19_themes_messages", "q20_evolution",
  "q21_balance", "q22_causes", "q23_fan_moment",
  "q24_inspiration", "q25_legacy",
];

const OPTIONAL_FIELDS = ["artist_phone", "artist_social", "current_city"];

const MAX_FIELD_LEN = 4000;
const MAX_PAYLOAD_KB = 200;


type SurveyData = Record<string, string>;

const Q_LABELS: [string, string][] = [
  ["q1_birthplace_birthdate", "Where and when were you born?"],
  ["q2_love_for_music", "When did you first discover your love for music?"],
  ["q3_grow_up_listening", "What kind of music did you grow up listening to?"],
  ["q4_influencers", "Family members or friends who influenced your musical journey?"],
  ["q5_first_instrument_song", "First instrument you played or first song you sang?"],
  ["q6_formal_training", "Did you receive any formal musical training or education?"],
  ["q7_mentors", "Mentors, teachers, or role models who shaped your musical path?"],
  ["q8_early_lesson", "Most valuable lesson you learned about music early on?"],
  ["q9_education_influence", "How did your educational background influence your approach to music?"],
  ["q10_school_activities", "Did you participate in school bands, choirs, or other musical activities?"],
  ["q11_pursue_music", "What inspired you to pursue music as a career?"],
  ["q12_first_break", "Can you describe your first major break or performance?"],
  ["q13_challenges", "Most challenging aspect of building your music career?"],
  ["q14_proudest_work", "Songs or projects you are most proud of, and why?"],
  ["q15_awards_recognition", "Awards or notable recognition for your work?"],
  ["q16_style_genre", "How would you describe your style or genre of music?"],
  ["q17_inspirations", "Biggest musical inspirations, past or present?"],
  ["q18_creative_process", "Creative process when writing songs or composing music?"],
  ["q19_themes_messages", "Specific themes or messages you aim to convey through your music?"],
  ["q20_evolution", "How has your music evolved over the years?"],
  ["q21_balance", "How do you balance your personal life with your music career?"],
  ["q22_causes", "Causes or charities important to you as an artist?"],
  ["q23_fan_moment", "Most memorable moment of connecting with your fans?"],
  ["q24_inspiration", "How do you stay inspired and motivated to create new music?"],
  ["q25_legacy", "What legacy do you hope to leave in the music world?"],
];

const ARCHITECT_PUBLICIST_SYSTEM = `You are Avery Cole, a top-tier music publicist. You don't write bios — you build narratives that make people pay attention. You see artists as brands in motion, not just creatives. You understand how media, labels, and fans scan for signals. You write with precision, not fluff. Every sentence answers: Why should anyone care right now?

Your job: Take the artist's survey responses and turn them into a press-ready artist bio in your signature voice.

Core principles:
1. Authority without arrogance. Sound established — even if the artist is emerging. Assume attention, never beg for it.
2. Specificity over hype. "Blending Detroit house textures with Southern trap cadence" beats "talented and versatile" every time.
3. Momentum framing. Always implies trajectory. The reader should feel like they're catching the artist at the right time.
4. Clean, cinematic phrasing. Short, punchy sentences mixed with occasional longer, flowing lines. Reads like a press feature, never a résumé.

Bio structure:
1. Opening line = positioning statement. One sentence that instantly defines the artist's lane and edge.
2. Sonic identity. What they sound like + what makes it distinct.
3. Proof of movement. Credits, placements, collaborations, growth signals — understated, never a list.
4. Narrative layer. Background, influence, or why. Kept tight. No childhood ramble.
5. Forward momentum. What's next + why people should watch now.

Signature techniques: Implied Cosign, Cultural Anchoring, Understatement Flex, and Future Casting — only when the source material supports it.

Hard rules:
- Never use generic adjectives: talented, dope, fire, passionate, versatile, unique, authentic, vibes.
- Never use desperation language: looking to, hoping to, aspiring to, trying to break into.
- Never use cluttered timelines, résumé tone, or long childhood anecdotes.
- Never use the word "journey". Never use "musical journey".
- Never fabricate credits, awards, placements, collaborations, numbers, or geography.
- Use the Pronouns field as source of truth. If blank, use they/them. Never infer pronouns from the name.
- If Current City is provided, use it. If not, do not invent a city.

Banned phrases: journey, musical journey, humble beginnings, against all odds, testament, ever-evolving, genre-bending, pushing the boundaries, in an era of, in a world of, poised to, game-changer, trailblazer, next big thing, voice of a generation, raw talent, undeniable talent, one to watch, dream, dreamer, soulful, authentic, real, genuine.

Output exactly this structure in clean Markdown:
# Artist Bio Kit

## EPK Blurb
One sentence, 30 words max.

## Short Bio
About 100 words.

## Press Bio
About 250 words. This is the canonical bio.

## Long-Form Feature
500–650 words.

## Notable Angles for Press
3–5 bullets.

If material is thin, include bracketed [BIO GAP: ...] notes. Do not invent facts.`;

function buildQA(data: SurveyData) {
  const lines: string[] = [];
  lines.push(`Artist Name: ${data.artist_name || ""}`);
  lines.push(`Pronouns: ${data.pronouns || ""}`);
  lines.push(`Email: ${data.artist_email || ""}`);
  if (data.artist_phone) lines.push(`Phone: ${data.artist_phone}`);
  if (data.artist_social) lines.push(`Primary Social: ${data.artist_social}`);
  if (data.current_city) lines.push(`Current City: ${data.current_city}`);
  lines.push("");
  Q_LABELS.forEach(([key, label], idx) => {
    lines.push(`Question ${idx + 1}`);
    lines.push(label);
    lines.push(`Answer ${idx + 1}`);
    lines.push(data[key] || "");
    lines.push("");
  });
  return lines.join("\n").trim();
}

function extractResponseText(result: any): string {
  if (typeof result?.output_text === "string") return result.output_text.trim();
  const chunks: string[] = [];
  for (const item of result?.output ?? []) {
    for (const content of item?.content ?? []) {
      if (typeof content?.text === "string") chunks.push(content.text);
    }
  }
  return chunks.join("\n").trim();
}

async function callOpenAIResponses(qa: string) {
  if (!OPENAI_API_KEY) throw new Error("openai_key_missing");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 55_000);
  try {
    const res = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: OPENAI_MODEL,
        input: [
          { role: "system", content: [{ type: "input_text", text: ARCHITECT_PUBLICIST_SYSTEM }] },
          { role: "user", content: [{ type: "input_text", text: `Write a bio for this person.\n\n${qa}\n\nDeliver all four lengths plus 3–5 press angles. Hold the line on the hard rules. Flag bio gaps where needed — do not invent.` }] },
        ],
        temperature: 0.72,
        max_output_tokens: 3200,
      }),
      signal: controller.signal,
    });
    const result = await res.json().catch(() => null);
    if (!res.ok) {
      const code = result?.error?.code || result?.error?.type || `openai_http_${res.status}`;
      throw new Error(code);
    }
    const bio = extractResponseText(result);
    if (!bio) throw new Error("openai_empty_output");
    return { bio, model: OPENAI_MODEL, provider: "openai" };
  } finally {
    clearTimeout(timeout);
  }
}

async function callOpenRouterChat(qa: string) {
  if (!OPENROUTER_API_KEY) throw new Error("openrouter_key_missing");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 55_000);
  try {
    const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${OPENROUTER_API_KEY}`,
        "Content-Type": "application/json",
        "HTTP-Referer": "https://loudmusic.io",
        "X-Title": "LOUDmusic Artist Bio Survey",
      },
      body: JSON.stringify({
        model: OPENROUTER_MODEL,
        messages: [
          { role: "system", content: ARCHITECT_PUBLICIST_SYSTEM },
          { role: "user", content: `Write a bio for this person.\n\n${qa}\n\nDeliver all four lengths plus 3–5 press angles. Hold the line on the hard rules. Flag bio gaps where needed — do not invent.` },
        ],
        temperature: 0.72,
        max_tokens: 3200,
      }),
      signal: controller.signal,
    });
    const result = await res.json().catch(() => null);
    if (!res.ok) {
      const msg = result?.error?.code || result?.error?.message || `openrouter_http_${res.status}`;
      throw new Error(msg);
    }
    const bio = String(result?.choices?.[0]?.message?.content || "").trim();
    if (!bio) throw new Error("openrouter_empty_output");
    return { bio, model: result?.model || OPENROUTER_MODEL, provider: "openrouter" };
  } finally {
    clearTimeout(timeout);
  }
}

async function generateArtistBio(data: SurveyData) {
  const qa = buildQA(data);
  try {
    const generated = await callOpenAIResponses(qa);
    return { ...generated, qa };
  } catch (openaiError) {
    // Current OpenAI key can be over quota; don't block artists from receiving a bio.
    console.error("openai_generation_failed", openaiError instanceof Error ? openaiError.message : openaiError);
    const generated = await callOpenRouterChat(qa);
    return { ...generated, qa, fallback_from: "openai" };
  }
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function bad(msg, status = 400) {
  return json({ ok: false, error: msg }, status);
}

function ipFrom(req) {
  return (
    req.headers.get("cf-connecting-ip") ??
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip") ??
    "0.0.0.0"
  );
}

async function hashIp(ip) {
  const data = new TextEncoder().encode(ip + IP_SALT);
  const buf = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 32);
}

const BUCKET = new Map();
function rateLimit(ipHash, limit = 3, windowMs = 60_000) {
  const now = Date.now();
  const entry = BUCKET.get(ipHash);
  if (!entry || entry.reset < now) {
    BUCKET.set(ipHash, { count: 1, reset: now + windowMs });
    return { ok: true, remaining: limit - 1 };
  }
  if (entry.count >= limit) {
    return { ok: false, remaining: 0, resetMs: entry.reset - now };
  }
  entry.count += 1;
  return { ok: true, remaining: limit - entry.count };
}

function isEmail(s) {
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s);
}

function isString(v) {
  return typeof v === "string";
}

function sanitize(s) {
  return s.replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, "").trim();
}

// Serve the HTML form. The HTML is imported as text via import attributes,
// so it's bundled alongside the function at deploy time.
function serveFormHtml() {
  return formHtml;
}

const REDIRECT_HTML = `<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=https://docs.loudmusic.io/s/d7Cz4n6gjerystP"><title>Form</title></head>
<body><p>Loading form...</p></body>
</html>`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  // If GET request, serve the HTML form directly from this function URL.
  // This means the Edge Function URL doubles as the public form URL.
  if (req.method === "GET") {
    const accept = (req.headers.get("accept") ?? "").toLowerCase();
    // Serve HTML to browsers. API callers won't send text/html by default,
    // so programmatic clients won't accidentally get the form HTML.
    if (accept.includes("text/html") || accept.includes("*/*")) {
      try {
        const html = serveFormHtml();
        return new Response(html, {
          status: 200,
          headers: {
            ...CORS,
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "public, max-age=300",
            "X-Served-By": "artist-bio-survey-form",
          },
        });
      } catch (e) {
        console.error("serve_html_failed", e);
        return new Response(REDIRECT_HTML, {
          status: 200,
          headers: { "Content-Type": "text/html; charset=utf-8", ...CORS },
        });
      }
    }
    return json({
      ok: true,
      name: "artist-bio-survey",
      status: "healthy",
      endpoints: {
        form_html: "GET this URL with Accept: text/html",
        submit: "POST this URL with application/json",
      },
    });
  }

  if (req.method !== "POST") return bad("method_not_allowed", 405);

  const contentLength = Number(req.headers.get("content-length") ?? "0");
  if (contentLength > MAX_PAYLOAD_KB * 1024) return bad("payload_too_large", 413);

  let body;
  try {
    body = await req.json();
  } catch {
    return bad("invalid_json");
  }
  if (!body || typeof body !== "object") return bad("invalid_body");

  const data = body;
  const ip = ipFrom(req);
  const ipHash = await hashIp(ip);
  const rl = rateLimit(ipHash);
  if (!rl.ok) {
    return json({ ok: false, error: "rate_limited", retry_after_ms: rl.resetMs }, 429);
  }

  const missing = [];
  for (const k of REQUIRED_FIELDS) {
    if (!isString(data[k]) || sanitize(data[k]).length === 0) missing.push(k);
  }
  if (missing.length > 0) {
    return bad(
      "missing_fields: " + missing.slice(0, 5).join(", ") +
      (missing.length > 5 ? ` (+${missing.length - 5} more)` : "")
    );
  }

  if (!isEmail(sanitize(data.artist_email))) return bad("invalid_email");

  // Pronouns sanity check: must be one of the allowed tokens or a short custom string
  const pronouns = sanitize(data.pronouns);
  if (pronouns.length > 40) return bad("pronouns_too_long");

  const row: Record<string, string | null> = { ip_hash: ipHash, pronouns };
  for (const k of [...REQUIRED_FIELDS, ...OPTIONAL_FIELDS]) {
    if (k === "pronouns") continue;
    const v = data[k];
    if (isString(v)) {
      const s = sanitize(v);
      row[k] = s.length > MAX_FIELD_LEN ? s.slice(0, MAX_FIELD_LEN) : s;
    }
  }
  row.user_agent = req.headers.get("user-agent")?.slice(0, 500) ?? null;

  const supabase = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false },
  });

  const { data: inserted, error: insertErr } = await supabase
    .from("artist_bio_surveys")
    .insert(row)
    .select("id")
    .single();

  if (insertErr || !inserted) {
    console.error("insert_failed", insertErr);
    return bad("insert_failed: " + (insertErr?.message ?? "unknown"), 500);
  }

  const cleanData: SurveyData = { pronouns };
  for (const k of [...REQUIRED_FIELDS, ...OPTIONAL_FIELDS]) {
    if (k === "pronouns") continue;
    const v = row[k];
    if (typeof v === "string") cleanData[k] = v;
  }

  try {
    const generated = await generateArtistBio(cleanData);
    return json({
      ok: true,
      id: inserted.id,
      bio: generated.bio,
      model: generated.model,
      qa: generated.qa,
      bio_status: "generated",
    });
  } catch (e) {
    console.error("bio_generation_failed", e?.message ?? e);
    return json({
      ok: true,
      id: inserted.id,
      bio: null,
      bio_status: "failed",
      bio_error: "bio_generation_failed",
      qa: buildQA(cleanData),
    });
  }
});
