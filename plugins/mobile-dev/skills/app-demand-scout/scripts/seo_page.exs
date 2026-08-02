#!/usr/bin/env elixir
#
# seo_page.exs — static app landing / SEO page generator (skill #4).
#
# Produces a real, self-contained index.html: SEO meta tags (title, description,
# Open Graph), an H1 with your target keyword, a features list, a store CTA, an
# FAQ (good for search snippets), and JSON-LD SoftwareApplication schema.
#
# Doubles as a fake-door validation page: point ads/Reddit/TikTok at it, capture
# emails, measure interest before building. Host free (Netlify/Cloudflare Pages/
# GitHub Pages) or drop into Supabase.
#
# No dependencies, no network. Pure template.
#
# Run:
#   elixir seo_page.exs --name "VestTrack" --keyword "RSU tracker" \
#     --tagline "Track your RSU & equity vesting without spreadsheets" \
#     --features "Vesting schedule timeline,Tax withholding estimates,Multi-grant support,Price alerts" \
#     --store-url "https://apps.apple.com/app/idXXXXXXXX" --out index.html

defmodule SEOPage do
  def main(argv) do
    {opts, _rest, _} =
      OptionParser.parse(argv,
        strict: [
          name: :string, keyword: :string, tagline: :string,
          features: :string, store_url: :string, out: :string,
          accent: :string, waitlist: :boolean
        ]
      )

    name = opts[:name] || raise("--name required")
    keyword = opts[:keyword] || name
    tagline = opts[:tagline] || "#{name} — the app that finally does it right."
    accent = opts[:accent] || "#4f46e5"
    store_url = opts[:store_url]
    waitlist = opts[:waitlist] || is_nil(store_url)

    features =
      (opts[:features] || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    html = render(name, keyword, tagline, features, store_url, waitlist, accent)
    out = opts[:out] || "index.html"
    File.write!(out, html)
    IO.puts("landing page -> #{out}  (#{String.length(html)} bytes, #{length(features)} features)")
  end

  def render(name, keyword, tagline, features, store_url, waitlist, accent) do
    title = "#{name} — #{keyword}"
    desc = String.slice(tagline, 0, 155)

    feature_html =
      features
      |> Enum.map(fn f -> ~s(      <li><span class="dot"></span>#{esc(f)}</li>) end)
      |> Enum.join("\n")

    cta_html =
      if waitlist do
        """
            <form class="cta" onsubmit="event.preventDefault();this.querySelector('.msg').textContent='Thanks — we\\'ll email you at launch.';">
              <input type="email" required placeholder="you@email.com" aria-label="email" />
              <button type="submit">Notify me at launch</button>
              <p class="msg"></p>
            </form>
            <p class="sub">Join the waitlist. No spam, launch email only.</p>
        """
      else
        """
            <a class="cta-btn" href="#{esc(store_url)}">Download on the App Store</a>
        """
      end

    faq =
      [
        {"Is #{name} free?", "Start free. Upgrade only if it saves you time."},
        {"What makes #{name} different?", esc(tagline)},
        {"Which platforms?", "iOS and Android."}
      ]
      |> Enum.map(fn {q, a} ->
        """
              <details>
                <summary>#{esc(q)}</summary>
                <p>#{a}</p>
              </details>
        """
      end)
      |> Enum.join("\n")

    jsonld =
      ~s({"@context":"https://schema.org","@type":"SoftwareApplication",) <>
        ~s("name":"#{esc(name)}","applicationCategory":"MobileApplication",) <>
        ~s("operatingSystem":"iOS, Android","description":"#{esc(desc)}"})

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>#{esc(title)}</title>
      <meta name="description" content="#{esc(desc)}" />
      <meta property="og:title" content="#{esc(title)}" />
      <meta property="og:description" content="#{esc(desc)}" />
      <meta property="og:type" content="website" />
      <meta name="twitter:card" content="summary_large_image" />
      <link rel="canonical" href="/" />
      <script type="application/ld+json">#{jsonld}</script>
      <style>
        :root { --accent: #{accent}; }
        * { box-sizing: border-box; }
        body { margin:0; font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
               color:#111; background:#fff; }
        .wrap { max-width:720px; margin:0 auto; padding:64px 20px; }
        h1 { font-size:2.4rem; line-height:1.15; margin:0 0 12px; letter-spacing:-.02em; }
        .tag { font-size:1.2rem; color:#444; margin:0 0 32px; }
        ul { list-style:none; padding:0; margin:0 0 32px; }
        li { display:flex; align-items:center; gap:10px; padding:8px 0; font-size:1.05rem; }
        .dot { width:8px; height:8px; border-radius:50%; background:var(--accent); flex:0 0 auto; }
        .cta input { padding:12px 14px; font-size:1rem; border:1px solid #ccc; border-radius:8px; width:100%; margin-bottom:10px; }
        .cta button, .cta-btn { display:inline-block; background:var(--accent); color:#fff; border:0;
               padding:13px 22px; font-size:1rem; border-radius:8px; cursor:pointer; text-decoration:none; }
        .sub { color:#888; font-size:.9rem; margin-top:8px; }
        .msg { color:var(--accent); font-weight:600; }
        details { border-top:1px solid #eee; padding:14px 0; }
        summary { cursor:pointer; font-weight:600; }
        footer { color:#aaa; font-size:.85rem; margin-top:48px; }
      </style>
    </head>
    <body>
      <main class="wrap">
        <h1>#{esc(name)}</h1>
        <p class="tag">#{esc(tagline)}</p>
        <ul>
    #{feature_html}
        </ul>
    #{cta_html}
        <h2 style="margin-top:56px;">FAQ</h2>
    #{faq}
        <footer>© #{esc(name)}. Built for people who search "#{esc(keyword)}".</footer>
      </main>
    </body>
    </html>
    """
  end

  defp esc(nil), do: ""
  defp esc(s) do
    s
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end

unless System.get_env("SCOUT_LIB") == "1", do: SEOPage.main(System.argv())
