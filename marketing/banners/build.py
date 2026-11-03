#!/usr/bin/env python3
"""Generates the web banners (HTML sources) in this folder. Render PNGs with render.js.
Colors come from MilesProSync/Assets.xcassets and Views/AppTheme.swift."""
import pathlib

OUT = pathlib.Path(__file__).parent
CSS = """
*{box-sizing:border-box;margin:0;padding:0}
body{width:%(w)dpx;height:%(h)dpx;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display','Segoe UI',Helvetica,Arial,sans-serif;
background:linear-gradient(135deg,#244DBA 0%%,#0A576B 100%%);color:#fff;position:relative}
.wrap{position:absolute;inset:0;display:flex;%(dir)s;align-items:%(align)s;justify-content:%(just)s;padding:%(pad)dpx;gap:%(gap)dpx}
.icon{width:%(icon)dpx;height:%(icon)dpx;border-radius:22%%;box-shadow:0 6px 18px rgba(0,0,0,.28);flex:none}
.txt{display:flex;flex-direction:column;gap:%(tg)dpx;%(txtalign)s}
h1{font-size:%(h1)dpx;line-height:1.08;font-weight:800;letter-spacing:-.02em}
h1 em{font-style:normal;color:#FFD36E}
p{font-size:%(p)dpx;line-height:1.25;color:#E6EEFF}
.chips{display:%(chips)s;gap:6px;flex-wrap:wrap}
.chip{font-size:%(c)dpx;font-weight:700;padding:3px 9px;border-radius:99px;background:rgba(255,255,255,.14)}
.chip.b{background:#fff;color:#244DBA}.chip.p{background:#62D8CF;color:#14243B}
.cta{display:inline-block;background:#FFD36E;color:#14243B;font-weight:800;font-size:%(ctasize)dpx;padding:%(cp)s;border-radius:99px;white-space:nowrap}
.price{font-size:%(p2)dpx;color:#BFD0F5}
.fine{position:absolute;right:8px;bottom:4px;font-size:9px;color:#9FB6E8;display:%(fine)s}
"""
def banner(name, w, h, headline, sub, label="Download on the App Store", **o):
    d = dict(w=w,h=h,dir="flex-direction:row",align="center",just="space-between",pad=16,gap=14,icon=64,tg=6,
             txtalign="",h1=26,p=14,c=11,ctasize=14,cp="9px 18px",p2=12,chips="none",fine="none")
    d.update(o)
    chips = '<div class="chips"><span class="chip b">Business</span><span class="chip p">Personal</span></div>'
    price = '<div class="price">From $39.99/year &middot; 1-day free trial</div>' if o.get("showprice") else ""
    sub_html = f"<p>{sub}</p>" if sub else ""
    body = f"""<div class="wrap"><img class="icon" src="assets/icon.png" alt="">
<div class="txt"><h1>{headline}</h1>{sub_html}{chips if d['chips']!='none' else ''}{price}</div>
<span class="cta">{label}</span></div>
<div class="fine">Estimates only. Not tax advice.</div>"""
    d.pop("showprice", None)
    html = f"<!doctype html><meta charset=utf-8><title>{name}</title><style>{CSS % d}</style>{body}"
    (OUT / f"{name}.html").write_text(html)

H = 'Every drive logged. <em>Automatically.</em>'
S = 'Repeat routes classify themselves.'
# name, w, h, kwargs
banner("leaderboard-728x90", 728, 90, H, "", pad=12, icon=62, h1=22, ctasize=13, cp="9px 16px")
banner("mobile-320x50", 320, 50, "Mileage log, <em>on autopilot</em>", "", label="Get it", pad=6, icon=38, h1=14, cp="6px 12px", gap=8)
banner("medium-rectangle-300x250", 300, 250, H, S, dir="flex-direction:column", align="flex-start", just="center", pad=20, gap=12, icon=56, h1=26, p=14, ctasize=14, showprice=True)
banner("large-rectangle-336x280", 336, 280, H, S, dir="flex-direction:column", align="flex-start", just="center", pad=22, gap=14, icon=60, h1=28, p=15, showprice=True)
banner("half-page-300x600", 300, 600, H, "Repeat routes classify themselves, so your mileage log is tax-ready without the swiping.", dir="flex-direction:column", align="flex-start", just="center", pad=26, gap=22, icon=84, h1=38, p=17, chips="flex", c=13, ctasize=16, cp="12px 22px", showprice=True, fine="block")
banner("wide-skyscraper-160x600", 160, 600, "Every drive logged. <em>Auto&shy;matically.</em>", S, label="Get the app", dir="flex-direction:column", align="center", just="center", pad=16, gap=24, icon=72, h1=26, p=14, txtalign="text-align:center;align-items:center", ctasize=14, cp="10px 14px", showprice=True)
banner("billboard-970x250", 970, 250, H, "Repeat routes classify themselves, so your mileage log is tax-ready without the swiping.", pad=32, gap=28, icon=120, h1=44, p=19, chips="flex", c=13, ctasize=20, cp="14px 28px", p2=14, showprice=True, fine="block")
banner("social-1200x628", 1200, 628, H, "Repeat routes classify themselves, so your mileage log is tax-ready without the swiping.", dir="flex-direction:column", align="flex-start", just="center", pad=80, gap=34, icon=130, h1=84, p=32, chips="flex", c=20, ctasize=28, cp="18px 36px", p2=22, showprice=True, fine="block")
