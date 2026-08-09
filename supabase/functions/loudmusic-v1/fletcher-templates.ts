// Fletcher Method funnel templates (Zero Selling System™, Winning Workshop™).
//
// Canonical, code-versioned definitions used by createFunnel()/GET
// /funnel-templates in index.ts. Kept in code (not editable DB rows) so a
// user action can never mutate the master template — creating a funnel
// always clones fresh funnel_steps + funnel_page_versions rows from here.
//
// Content is transcribed block-for-block from Fletcher's supplied HTML
// (workspace-kit/Winning Workshop Funnel Template/*.html and
// workspace-kit/Zero Selling System funnel/*.html): same section order,
// same headlines, same CTA copy, same testimonials. Only structural changes
// were made — splitting each page into typed blocks and extracting repeated
// facts (business name, workshop date, price, etc.) into `{ $var: "key" }`
// references resolved against the funnel's `settings.variables` at read
// time (see resolveVars in index.ts), so editing one field updates every
// page that uses it.

export type FunnelVariables = Record<string, unknown>;

export interface TemplateStep {
  stepKey: string;
  name: string;
  stepType: "landing" | "form" | "thank_you" | "booking" | "checkout" | "content" | "redirect" | "error";
  blocks: Record<string, unknown>[];
}

export interface FletcherTemplate {
  key: string; // "zss" | "ww"
  version: string;
  name: string;
  description: string;
  defaultVariables: FunnelVariables;
  requiredStepKeys: string[];
  steps: TemplateStep[];
}

const sharedDefaults: FunnelVariables = {
  businessName: "The Client Engine",
  presenterName: "[Your Name]",
  presenterCredLine: "[X] years in [industry] · Helped [X] clients achieve [specific result]",
  guaranteeText: "100% money-back guarantee. If it isn't worth 10x what you paid, you get every penny back. No questions asked.",
  supportEmail: "support@example.com",
  communityUrl: "https://www.skool.com/",
  brandColors: { primary: "#52CDBD", dark: "#1B2A4A", gold: "#C9A84C" },
};

const roadmap = {
  id: "roadmap",
  type: "roadmapCard",
  eyebrow: { $var: "businessName" },
  title: "The 3-Stage Client Acquisition System",
  subtitle: "Your complete roadmap from stranger to signed client in 90 days or less",
  stages: ["Foundation", "Attraction", "Conversion"],
  steps: [
    { name: "Define Your Offer", desc: "Lock your message" },
    { name: "Map Your System", desc: "Build the roadmap" },
    { name: "Pick Your Model", desc: "Price & path" },
    { name: "Write Your Script", desc: "Core copy blocks" },
    { name: "Build the Magnet", desc: "Lead capture tool" },
    { name: "Record Your Video", desc: "Trust builder" },
    { name: "Launch Your Funnel", desc: "Pages & flow" },
    { name: "Run Paid Sessions", desc: "Close clients" },
    { name: "Scale & Optimize", desc: "Compound results" },
  ],
  metrics: [
    { value: "3–5", label: "New clients / week" },
    { value: "90", label: "Days to full system" },
    { value: "$0", label: "Ad spend required" },
  ],
};

const wwTestimonials = [
  { quote: "I attended the workshop on a whim and walked away with a complete plan. Within 30 days I had 4 new clients and turned my ads off.", author: "Michael R.", role: "Marketing Consultant", stars: 5 },
  { quote: "Best 60 minutes I've spent on my business all year. No fluff, no pitch for the first 45 minutes — just real strategy I could use that day.", author: "Jessica T.", role: "Health Coach", stars: 5 },
  { quote: "I've done a dozen webinars this year. This was the first one where I actually built something during the session and used it the next day.", author: "David K.", role: "Executive Coach", stars: 5 },
];

const winningWorkshop: FletcherTemplate = {
  key: "ww",
  version: "1.0.0",
  name: "Fletcher — Winning Workshop™",
  description: "Live-workshop funnel: registration page, confirmation page (belief-shift video + pre-work), and a time-limited replay page.",
  requiredStepKeys: ["registration", "confirmation"],
  defaultVariables: {
    ...sharedDefaults,
    workshopTitle: "The New One-Page System We Use to Sign 3–5 New Clients Every Week",
    workshopDate: new Date(Date.now() + 14 * 86400000).toISOString(),
    workshopDurationMinutes: 60,
    workshopTimezoneLabel: "EST",
    ctaLabel: "Save My Seat — It's Free →",
    replayExpiresAt: new Date(Date.now() + 16 * 86400000).toISOString(),
  },
  steps: [
    {
      stepKey: "registration",
      name: "Registration Page",
      stepType: "landing",
      blocks: [
        { id: "hero", type: "hero", badge: { text: "Free Live Workshop", variant: "live" }, preHeadline: "For Coaches, Consultants & Agency Owners", headline: "The New One-Page System We Use to Sign **3–5 New Clients Every Week**", subHeadline: "Without complicated funnels, awkward sales calls, or spending another dollar on ads that don't convert" },
        { id: "eventInfo", type: "eventInfoBar" },
        { id: "countdown", type: "countdown", label: "Workshop Starts In" },
        roadmap,
        { id: "socialProof", type: "socialProofQuote", registrantCountText: "347 Coaches Already Registered", stars: 5, quote: "I signed 3 new clients in my first 2 weeks using this system. I wish I had this a year ago.", author: "Sarah M., Business Coach" },
        { id: "ctaTop", type: "ctaButton", label: { $var: "ctaLabel" }, note: "Free live workshop · Limited spots · Replay available for 48 hours", style: "primary", formBlockId: "regForm" },
        { id: "benefitsHeading", type: "sectionHeading", label: "What You'll Walk Away With", title: "In 60 Minutes, You'll Have a Clear Plan to Get Clients Every Week" },
        { id: "benefits", type: "benefitsList", items: [
          "The exact one-page system that replaces complicated funnels with a simple, repeatable client acquisition process",
          "Why most marketing fails — and the single structural fix that makes everything else work",
          "A live walkthrough where you'll start building your own framework during the session — not just theory",
          "The \"one-page secret\" that's helping coaches sign 3-5 clients per week without ads, funnels, or free calls",
        ] },
        { id: "presenter", type: "presenterCred", name: { $var: "presenterName" }, credLine: { $var: "presenterCredLine" } },
        { id: "testimonials", type: "testimonialsList", layout: "stack", items: wwTestimonials.slice(0, 2) },
        { id: "ctaRepeat", type: "ctaButton", label: { $var: "ctaLabel" }, note: "Free live workshop · Takes 10 seconds to register", style: "secondary", formBlockId: "regForm" },
        { id: "regForm", type: "formEmbed", presentation: "modal", headline: "Save Your Seat for the Free Workshop", subtext: "Join 347 coaches already registered", fields: ["firstName", "email"], submitLabel: "Register Now — It's Free →", note: "We'll send your Zoom link and calendar invite immediately." },
      ],
    },
    {
      stepKey: "confirmation",
      name: "Confirmation Page",
      stepType: "thank_you",
      blocks: [
        { id: "hero", type: "hero", badge: { text: "You're Registered — You're In!", variant: "confirmed" }, preHeadline: "Your spot is saved. Check your email for the Zoom link. **Before you go — watch this 5-minute video right now.**", headline: "How to Get the **Most Out of This Workshop**", subHeadline: "This quick video will show you exactly what to expect and one thing to do before we meet that will make the session 10x more valuable for you." },
        { id: "video", type: "videoEmbed", label: "Watch Before the Workshop", durationLabel: "5 min · This will double the value of your session" },
        { id: "eventInfo", type: "eventInfoBar" },
        { id: "calendarBtn", type: "calendarButton", label: "Add to My Calendar" },
        { id: "preworkHeading", type: "sectionHeading", label: "Before the Workshop", title: "Do This One Thing to Get 10x More Value", subtext: "People who complete this quick exercise before the workshop get dramatically better results from the session. It takes 5 minutes." },
        { id: "prework", type: "preworkCard", badge: "Your Pre-Work", task: "Write down the 3 biggest struggles your ideal clients come to you with.", description: "Open a note on your phone or a Google Doc. Think about the last 5-10 people who asked for your help. What were they stuck on? What pain were they trying to solve? Write down the top 3. Bring this to the workshop.", timeEstimate: "Takes about 5 minutes" },
        { id: "agenda", type: "agendaSteps", heading: { label: "Workshop Agenda", title: "Here's Exactly What We'll Cover" }, items: [
          { time: "0–15 min", title: "The Problem With How You're Marketing Now", description: "Why most coaches are stuck — and the one structural mistake that's holding everything back." },
          { time: "15–40 min", title: "The One-Page System — Live Build", description: "I'll walk you through the exact framework and start building yours live." },
          { time: "40–50 min", title: "Proof + Case Studies", description: "Real results from real people using this system." },
          { time: "50–60 min", title: "Your Next Step", description: "How to take what you learned and implement it." },
        ] },
        { id: "proofHeading", type: "sectionHeading", label: "From Previous Attendees", title: "People Just Like You Are Getting Results" },
        { id: "testimonials", type: "testimonialsList", layout: "grid2", items: wwTestimonials },
      ],
    },
    {
      stepKey: "replay",
      name: "Replay Page",
      stepType: "landing",
      blocks: [
        { id: "urgencyBar", type: "urgencyBar", text: "⏰ This replay expires in 47 hours — watch it now before it's gone" },
        { id: "hero", type: "hero", badge: { text: "Replay — Limited Time", variant: "replay" }, preHeadline: "You missed the live session — or you want to watch it again. Either way, the full training is below.", headline: "Watch the Full Training: The New One-Page System to Sign **3–5 New Clients Every Week**", subHeadline: "Without complicated funnels, awkward sales calls, or spending another dollar on ads that don't convert" },
        { id: "video", type: "videoEmbed", url: { $var: "replayUrl" }, label: "Watch the Full Workshop Replay", durationLabel: "58:42 · The complete training from the live session" },
        { id: "expiry", type: "expiryNotice", text: { $var: "replayExpiresAt" } },
        { id: "ctaSection", type: "ctaSection", dividerText: "Ready to go deeper?", headline: "Build Your Complete Customer Engine", subtext: "Everything you saw in the workshop — plus hands-on coaching, AI tools, and step-by-step guides to build the whole system.", benefits: [
          "The complete system — not just the one step we covered today",
          "Weekly live coaching calls + direct feedback on your assets",
          "AI-powered tools that build your marketing content for you",
          "Step-by-step guides worth $500 each — included free",
        ], buttonLabel: "Join Customer Engine Academy →", trustBadges: ["Cancel anytime", "30-day money-back guarantee", "2,400+ members"] },
        { id: "proofGrid", type: "proofGrid", heading: { label: "Real Results", title: "What Happens When You Implement This System", subtext: "These are real results from people using the exact system you just saw in the training." }, items: [
          { kind: "quote", quote: "I went from zero online presence to 6 paying clients in 45 days. The system gave me the exact roadmap — I just followed it.", author: "[Client Name]", role: "[Their Title] · [Specific Result]", stars: 5 },
          { kind: "quote", quote: "I'd been stuck at $8K months for a year. After implementing the framework, I hit $22K the next month.", author: "[Client Name]", role: "[Their Title] · [Specific Result]", stars: 5 },
          { kind: "quote", quote: "The plan was so specific I knew exactly what to do Monday morning. Three weeks later I had my first $5K client.", author: "[Client Name]", role: "[Their Title] · [Specific Result]", stars: 5 },
          { kind: "quote", quote: "I was doing everything — posting, emailing, running ads — but nothing was connected. Now I have a system that actually works.", author: "[Client Name]", role: "[Their Title] · [Specific Result]", stars: 5 },
        ] },
        { id: "bottomCta", type: "bottomCta", headline: "Don't Let This Replay Expire Without Taking Action", subtext: "The training comes down in 47 hours. If you're ready to build the complete system, join the academy now.", buttonLabel: "Join Customer Engine Academy →", note: "Cancel anytime · 30-day money-back guarantee · 2,400+ members" },
      ],
    },
  ],
};

const zssBookingTestimonials = [
  { quote: "Within 30 minutes I had more clarity on my business than I'd gotten in 6 months of trying to figure it out on my own.", author: "Amanda L.", role: "Nutritionist · First $5K client in 3 weeks", stars: 5 },
  { quote: "I'd been stuck at $8K months for a year. After the session I restructured my offer and hit $22K the next month.", author: "James P.", role: "Business Strategist · $8K → $22K/month", stars: 5 },
  { quote: "The plan was so specific I knew exactly what to do Monday morning. No fluff, no theory — just the next steps.", author: "Sarah M.", role: "Business Coach · 3 clients in 2 weeks", stars: 5 },
  { quote: "Worth 10x what I paid. I finally understood why my funnel wasn't converting and fixed it in one afternoon.", author: "Rachel S.", role: "Course Creator · Funnel converting in 1 day", stars: 5 },
];

const zeroSelling: FletcherTemplate = {
  key: "zss",
  version: "1.0.0",
  name: "Fletcher — Zero Selling System™",
  description: "Paid-strategy-session funnel: opt-in, an Authority Amplifier thank-you page that sells the paid session (checkout embedded as a pop-up), a booking page, and a confirmation/proof-wall page.",
  requiredStepKeys: ["opt-in", "aa-thank-you", "booking", "confirmation"],
  defaultVariables: {
    ...sharedDefaults,
    productName: "Personalized 90-Day Client Acquisition Plan",
    price: 299,
    priceLabel: "one-time",
    ctaLabel: "Get the Free Checklist Now →",
  },
  steps: [
    {
      stepKey: "opt-in",
      name: "Opt-In Page",
      stepType: "landing",
      blocks: [
        { id: "hero", type: "hero", preHeadline: "For Coaches, Consultants & Agency Owners", headline: "The New One-Page System We Used to Sign **3–5 New Clients Every Week**", subHeadline: "Without complicated funnels, awkward sales calls, or spending another dollar on ads that don't convert" },
        roadmap,
        { id: "socialProof", type: "socialProofQuote", stars: 5, quote: "I signed 3 new clients in my first 2 weeks using this system. I wish I had this a year ago.", author: "Sarah M., Business Coach" },
        { id: "ctaTop", type: "ctaButton", label: { $var: "ctaLabel" }, note: "Free instant access · No spam · Unsubscribe anytime", style: "primary", formBlockId: "optinForm" },
        { id: "benefitsHeading", type: "sectionHeading", label: "What's Inside", title: "Everything You Need to Land Your Next Client This Week" },
        { id: "benefits", type: "benefitsList", items: [
          "The exact 3-step system that replaces complicated funnels with a simple, repeatable client acquisition process",
          "The #1 mistake coaches and consultants make that kills conversions — and the 5-minute fix that solves it",
          "The \"hot step\" shortcut that turns cold leads into paid strategy session bookings without free calls",
          "A fill-in-the-blank template you can complete in under 30 minutes and start using today",
        ] },
        { id: "credibility", type: "presenterCred", name: { $var: "presenterName" }, credLine: { $var: "presenterCredLine" } },
        { id: "testimonials", type: "testimonialsList", layout: "stack", items: [
          { quote: "Before this I was spending $2k a month on ads with nothing to show for it. Within 30 days of implementing the system, I had 4 new clients and turned my ads off completely.", author: "Michael R.", role: "Marketing Consultant", stars: 5 },
          { quote: "The checklist alone was worth more than the last course I paid $500 for. Simple, clear, and I knew exactly what to do next.", author: "Jessica T.", role: "Health Coach", stars: 5 },
        ] },
        { id: "ctaRepeat", type: "ctaButton", label: "Get the Free Checklist →", note: "Free instant access · Takes 30 seconds", style: "secondary", formBlockId: "optinForm" },
        { id: "optinForm", type: "formEmbed", presentation: "modal", headline: "Get the One-Page System to Sign 3–5 New Clients Every Week", subtext: "Enter your email and we'll send it straight to your inbox — plus a free video walkthrough showing you exactly how to use it.", fields: ["email"], submitLabel: "Send Me the Free Checklist →", note: "100% free · No spam · Unsubscribe anytime" },
      ],
    },
    {
      stepKey: "aa-thank-you",
      name: "AA Thank-You + Checkout",
      stepType: "checkout",
      blocks: [
        { id: "hero", type: "hero", badge: { text: "You're In — Check Your Inbox", variant: "confirmed" }, preHeadline: "Your **{{businessName}} Checklist** is on its way. Watch this quick video to see exactly how to use it right now.", headline: "The New One-Page System We Used to Sign **3–5 New Clients Every Week**", subHeadline: "Without complicated funnels, awkward sales calls, or spending another dollar on ads that don't convert" },
        { id: "video", type: "videoEmbed", label: "Watch the Free Training", durationLabel: "8 min · No opt-in required", revealCtaAtPercent: 60 },
        { id: "ctaSection", type: "ctaSection", dividerText: "Ready to get started?", headline: "Book Your Strategy Session", subtext: "In 45 minutes, we'll build your complete client acquisition plan together — or you get every penny back.", benefits: [
          "Custom client acquisition plan built for YOUR business",
          "Full audit of your current offer, messaging, and funnel",
          "Complete session recording you keep forever",
          "100% money-back guarantee if it's not worth 10x the price",
        ], buttonLabel: "Let's Build Your 90-Day Plan →", trustBadges: ["Secure Payment", "100% Money-Back Guarantee", "90% Show Rate"] },
        { id: "checkoutSummary", type: "checkoutSummary", badge: "Strategy Session", title: { $var: "productName" }, subtitle: "A 45-minute 1-on-1 session where we build your complete plan together.", benefits: ["45-minute 1-on-1 strategy session", "Custom client acquisition plan built for your business", "Recording of your session to keep forever", "100% money-back guarantee — no risk"], price: { $var: "price" }, priceLabel: { $var: "priceLabel" }, guaranteeText: { $var: "guaranteeText" } },
        { id: "checkoutForm", type: "checkoutForm", submitLabel: "Complete Purchase →" },
      ],
    },
    {
      stepKey: "booking",
      name: "Booking Page",
      stepType: "booking",
      blocks: [
        { id: "hero", type: "hero", headline: "You're Confirmed — Let's Do This", subHeadline: "I can't wait to help you get crystal clear on a powerful strategy you can start implementing over the next 90 days. Pick the time that works best for you below." },
        { id: "calendar", type: "calendarEmbed", bookingUrl: { $var: "bookingUrl" }, sessionBadge: "45 min session" },
        { id: "sidebar", type: "sessionDetailsCard", title: "90-Day Client Acquisition Plan", items: ["45 minutes — focused strategy", "1-on-1 Zoom call — not a group session", "Custom plan built for your business", "Full recording you keep forever"] },
        { id: "proofHeading", type: "sectionHeading", label: "What Others Are Saying", title: "People Just Like You Are Getting Results" },
        { id: "testimonials", type: "testimonialsList", layout: "grid2", items: zssBookingTestimonials },
      ],
    },
    {
      stepKey: "confirmation",
      name: "Booking Confirmation + Proof Wall",
      stepType: "thank_you",
      blocks: [
        { id: "hero", type: "hero", headline: "Your 90-Day Mapping Session Is Confirmed!", subHeadline: "Get ready to get crystal clear on the exact steps you should be taking to reach your goals. Here's everything you need to know before we meet." },
        { id: "sessionCard", type: "sessionDetailsCard", title: "Your Session Details", items: ["[Date & Time] — check your email for calendar invite", "45 minutes — focused strategy, no fluff", "Zoom call — link in your confirmation email", "You'll walk away with a custom client acquisition plan"] },
        { id: "expect", type: "agendaSteps", heading: { label: "Before Your Session", title: "Here's What to Expect" }, items: [
          { time: "1", title: "We Audit Your Current Setup", description: "We'll look at what you're doing now — your offer, your messaging, your funnel — and identify the biggest gaps." },
          { time: "2", title: "We Build Your Custom Plan", description: "Using the {{businessName}} framework, we'll map out your exact next steps." },
          { time: "3", title: "You Leave With a Roadmap", description: "A specific, documented plan you can start executing the same day." },
        ] },
        { id: "community", type: "communityCta", heading: "Join the Free Community", text: "Get access to the training library, connect with other business owners, and start learning before your session.", buttonLabel: "Join the Free Community →", note: "Free to join · 2,400+ members · Instant access" },
        { id: "proofWall", type: "proofGrid", heading: { label: "Results From Real Clients", title: "Here's What Happened After Their Session" }, items: [
          { kind: "video", featured: true, quote: "I went from zero online presence to 6 paying clients in 45 days. The strategy session gave me the exact roadmap — I just followed it.", author: "David K.", role: "Executive Coach · $18K in 45 days", stars: 5 },
          { kind: "quote", quote: "The plan was so specific I knew exactly what to do Monday morning. Three weeks later I had my first $5K client.", author: "Amanda L.", role: "Nutritionist", result: "First $5K client in 3 weeks", stars: 5 },
          { kind: "quote", quote: "I'd been stuck at $8K months for a year. After the session I restructured my offer and hit $22K the next month.", author: "James P.", role: "Business Strategist", result: "$8K → $22K/month", stars: 5 },
          { kind: "quote", quote: "Worth 10x what I paid. I finally understood why my funnel wasn't converting and fixed it in one afternoon.", author: "Rachel S.", role: "Course Creator", result: "Funnel converting in 1 day", stars: 5 },
          { kind: "quote", quote: "I was doing everything — posting, emailing, running ads — but nothing was connected. Now I have a system.", author: "Marcus T.", role: "Agency Owner", result: "Systemized in one session", stars: 5 },
        ] },
        { id: "valueWall", type: "valueWallGrid", heading: { label: "Start Learning Now", title: "Watch These Before Your Session" }, items: [
          { tag: "Foundation", title: "Why 96% of Your Success Is the Offer (Not the Marketing)", durationLabel: "6:42" },
          { tag: "Strategy", title: "The One-Page System That Replaces Your Entire Funnel", durationLabel: "8:15" },
          { tag: "Conversion", title: "Why Paid Sessions Convert 3x Better Than Free Calls", durationLabel: "5:30" },
        ] },
      ],
    },
  ],
};

export const FLETCHER_TEMPLATES: FletcherTemplate[] = [winningWorkshop, zeroSelling];

export function getFletcherTemplate(key: string): FletcherTemplate | null {
  return FLETCHER_TEMPLATES.find((t) => t.key === key) ?? null;
}

export function listFletcherTemplates() {
  return FLETCHER_TEMPLATES.map(({ key, version, name, description, requiredStepKeys }) => ({ key, version, name, description, requiredStepKeys }));
}

// Deep-resolves every { $var: "key" } reference in a block tree against a
// funnel's settings.variables. Used at read time (funnelDetail, publicFunnel)
// so editing one variable updates every page that references it — the
// stored blocks keep the reference, not a frozen copy of the value.
// Whole-field references ({ $var: "key" }) cover most cases, but some copy
// needs a variable embedded inside a larger sentence (e.g. "Your {{
// businessName }} Checklist is on its way"). Support both.
function interpolate(text: string, variables: FunnelVariables): string {
  return text.replace(/\{\{\s*(\w+)\s*\}\}/g, (_match, key: string) => {
    const value = variables[key];
    return value === undefined || value === null ? "" : String(value);
  });
}

export function resolveVars<T>(value: T, variables: FunnelVariables): T {
  if (value && typeof value === "object" && "$var" in (value as Record<string, unknown>) && typeof (value as Record<string, unknown>).$var === "string") {
    const key = (value as Record<string, unknown>).$var as string;
    return (variables[key] ?? "") as T;
  }
  if (typeof value === "string") return interpolate(value, variables) as unknown as T;
  if (Array.isArray(value)) return value.map((item) => resolveVars(item, variables)) as unknown as T;
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) out[k] = resolveVars(v, variables);
    return out as T;
  }
  return value;
}
