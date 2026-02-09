#!/usr/bin/env python3

import asyncio
from playwright.async_api import async_playwright
from datetime import date, timedelta, datetime
import json
import argparse
from datetime import datetime

# ========== CONFIG ==========
EZ_EMAIL = "mosweg1969@gmail.com"
EZ_PASSWORD = "5731StateLibraryNSW!"

EZPROXY_URL = "https://ezproxy.sl.nsw.gov.au/login?qurl=https%3A//www.libraryedition.com.au/truetoprint/fnc_login_network.php"
JSON_DIR = "/mnt/storage/Newspapers/The Sydney Morning Herald/Contents"

# ============================

def parse_args():
    parser = argparse.ArgumentParser(
        description="Download or inspect SMH edition via State Library ActivePaper"
    )
    parser.add_argument(
        "--date",
        required=True,
        help="Edition date in YYYY-MM-DD format (e.g. 2026-01-25)"
    )
    return parser.parse_args()


async def wait_for_selector_text(page, selector, text, timeout=15000):
    loc = page.locator(selector).filter(has_text=text)
    await loc.first.wait_for(timeout=timeout)
    return loc.first


async def extract_toc(page):
    print("📚 Extracting TOC from DOM...")

    toc = await page.evaluate("""
    () => {
        return [...document.querySelectorAll(".section-group")].map(group => {
            return {
                section: group.querySelector(".section-title")?.innerText.trim(),
                pages: [...group.querySelectorAll("[data-pageNo]")]
                        .map(p => p.getAttribute("data-pageNo"))
            }
        });
    }
    """)

    return toc

async def wait_for_day_list_refresh(page, timeout=15000):
    """
    Waits until the day list DOM actually changes after month/year selection
    """
    await page.wait_for_function("""
        () => {
            const ul = document.querySelector('.day_list');
            if (!ul) return false;
            const sig = ul.getAttribute('data-sig');
            const now = ul.innerText;
            if (!sig) {
                ul.setAttribute('data-sig', now);
                return false;
            }
            return sig !== now;
        }
    """, timeout=timeout)

async def ezproxy_member_login(page):
    print("🌐 Opening EZproxy wrapper...")
    await page.goto(EZPROXY_URL, wait_until="domcontentloaded")

    print("🧩 Waiting for SSO iframe...")
    iframe_locator = page.frame_locator("#member-sso-login-frame")

    # These selectors are inside the iframe
    email_input = iframe_locator.locator("input[type=email], input[name=email], input[name=username]")
    password_input = iframe_locator.locator("input[type=password]")
    submit_button = iframe_locator.locator("button[type=submit], input[type=submit]")

    print("⌛ Waiting for login fields...")
    await email_input.first.wait_for(timeout=30000)
    await password_input.first.wait_for(timeout=30000)

    print("✉️ Entering email...")
    await email_input.first.fill(EZ_EMAIL)

    print("🔐 Entering password...")
    await password_input.first.fill(EZ_PASSWORD)

    print("➡️ Submitting login...")
    async with page.expect_navigation(timeout=60000):
        await submit_button.first.click()

    print("✅ Login submitted")
    print("Current URL:", page.url)

    # Wait for ActivePaper / libraryedition landing
    await page.wait_for_url("**libraryedition**", timeout=60000)
    print("📚 ActivePaper loaded!")


async def dump_editions(app_frame):
    print("\n📚 Editions currently in DOM:")

    editions = await app_frame.evaluate("""
    () => {
        return Array.from(document.querySelectorAll("[data-href]"))
            .map(el => el.dataset.href)
            .filter(h => h && h.includes("/"))
    }
    """)

    if not editions:
        print("⚠️ No editions found in DOM")
        return

    for i, ed in enumerate(sorted(set(editions)), 1):
        print(f"{i:02d}. {ed}")

    print(f"\nTotal editions found: {len(set(editions))}\n")


async def ensure_year_loaded(app_frame, year, timeout=30000):
    print(f"🧭 Loading year {year}")

    # Click year
    await app_frame.evaluate(f"""
    () => {{
        const y = [...document.querySelectorAll(".year_list *")]
            .find(e => e.textContent.trim() === "{year}");
        if (!y) throw "Year not found in UI: {year}";
        y.click();
    }}
    """)

    await asyncio.sleep(5)


async def ensure_month_loaded(app_frame, month, target_href, timeout=30000):
    print(f"🧭 Ensuring DOM contains {target_href}")

    # Click month
    await app_frame.evaluate(f"""
    () => {{
        const m = [...document.querySelectorAll(".month_list li")]
            .find(e => e.textContent.trim().toLowerCase().startsWith("{month.lower()}"));
        if (!m) throw "Month not found in UI: {month}";
        m.click();
    }}
    """)

    # Wait for target edition to appear in DOM
    await app_frame.wait_for_function(
        f"""
        () => !![...document.querySelectorAll("[data-href]")]
            .map(e => e.dataset.href)
            .find(h => h === "{target_href}")
        """,
        timeout=timeout
    )

    print("✅ Target month loaded into DOM")


async def main():
    args = parse_args()

    try:
        target_date = datetime.strptime(args.date, "%Y-%m-%d")
    except ValueError:
        raise SystemExit("❌ Date must be in YYYY-MM-DD format")

    TARGET_YEAR = target_date.year
    PREV_MONTH = 0

    print(f"📅 Scraping JSON contents for {target_date}")

    async with async_playwright() as p:
        try:
            browser = await p.chromium.launch(headless=False)
            context = await browser.new_context()
            page = await context.new_page()

            # ---- LOGIN ----
            await ezproxy_member_login(page)

            # ---------- FIND ACTIVEPAPER IFRAME ----------
            print("🔎 Locating ActivePaper frame...")

            app_frame = None
            for frame in page.frames:
                if "libraryedition" in frame.url:
                    app_frame = frame
                    break

            if not app_frame:
                raise RuntimeError("❌ ActivePaper iframe not found")

            print("✅ ActivePaper frame ready:", app_frame.url)

            # ---------- WAIT FOR OLIVE CONTAINER TO EXIST ----------
            print("⏳ Waiting for Olive container (DOM)...")

            await app_frame.wait_for_selector(
                "#docViewerControl",
                state="attached",
                timeout=60000
            )

            print("✅ Olive container attached")

            print("🗂 Switching to Browse panel (text click)...")

            await app_frame.evaluate("""
            (() => {
              const candidates = [...document.querySelectorAll("button, div, span, a")];
              const browse = candidates.find(el =>
                el.textContent && el.textContent.trim().toLowerCase() === "browse"
              );
              if (!browse) throw "Browse control not found (text scan)";
              browse.click();
            })();
            """)

            await app_frame.wait_for_selector(".year_list", timeout=30000)

            await ensure_year_loaded(app_frame, TARGET_YEAR, timeout=30000)

            start_date = date(TARGET_YEAR, target_date.month, target_date.day)
            end_date = start_date

            current_date = start_date
            while current_date <= end_date:
                TARGET_YEAR = f"{current_date.year}"
                TARGET_MONTH = f"{current_date.month:02d}"
                TARGET_DAY = f"{current_date.day:02d}"

                target_href = f"SMH/{TARGET_YEAR}/{TARGET_MONTH}/{TARGET_DAY}"
                if current_date.month != PREV_MONTH:
                    PREV_MONTH = current_date.month

                    month_name = datetime.strptime(TARGET_MONTH, "%m").strftime("%B")
                    target_href = f"SMH/{TARGET_YEAR}/{TARGET_MONTH}/{TARGET_DAY}"

                    await ensure_month_loaded(
                        app_frame,
                        month_name,
                        target_href
                    )

                    await dump_editions(app_frame)

                print(f"📅 Opening edition {TARGET_YEAR}/{TARGET_MONTH}/{TARGET_DAY}")

                # ---------- OPEN EDITION BY DATE ----------
                date_path = f"{TARGET_YEAR}/{TARGET_MONTH}/{TARGET_DAY}"


                print(f"📅 Clicking edition")

                await app_frame.evaluate(f"""
                () => {{
                    const el = [...document.querySelectorAll("[data-href]")]
                        .find(e => e.dataset.href === "{target_href}");
                    if (!el) throw "Edition vanished from DOM";
                    el.click();
                }}
                """)

                await app_frame.evaluate(f"""
                (() => {{
                  const wanted = "{TARGET_YEAR}/{TARGET_MONTH}/{TARGET_DAY}";
                  const nodes = Array.from(document.querySelectorAll("[data-href]"));

                  const hit = nodes.find(el => el.dataset.href.includes(wanted));

                  if (!hit) {{
                    console.error("Available data-href values:", nodes.map(n => n.dataset.href));
                    throw "Edition not found in DOM for " + wanted;
                  }}

                  hit.click();
                }})();
                """)

                # ---------- SWITCH TO VIEWER ----------
                print("🖼 Opening edition...")
                viewer_btn = await wait_for_selector_text(page, "button.menu-button", "Viewer")
                await viewer_btn.click()

                print("⏳ Waiting for page renderer...")

                viewer_ready = page.locator(".replica-viewer .pageview")
                await viewer_ready.first.wait_for(timeout=30000)

                print("✅ Page rendered")

                print("🖼 Opening Thumbnails panel...")

                thumb_btn = page.locator("button[data-role='thumbnails']")
                await thumb_btn.wait_for(state="attached", timeout=30000)
                await viewer_ready.first.evaluate("""
                () => {
                  const btn = document.querySelector("button[data-role='thumbnails']");
                  if (!btn) throw "Thumbnails button not found";
                  btn.click();
                }
                """)

                thumb_popup = page.locator(".thumbnail-view")

                # Wait for it to EXIST first
                await thumb_popup.wait_for(state="attached", timeout=30000)

                # Then wait for it to become visible
                await page.wait_for_function("""
                () => {
                  const el = document.querySelector('.thumbnail-view');
                  return el && getComputedStyle(el).display !== 'none';
                }
                """, timeout=30000)

                print("✅ Thumbnails open")

                # ---------- EXTRACT TOC ----------
                toc = await extract_toc(page)

                print("\n====== TABLE OF CONTENTS ======\n")
                for entry in toc:
                    print(f"📌 {entry['section']}")
                    print(f"   Pages: {', '.join(entry['pages'])}\n")

                # Save TOC JSON file
                filename = f"{JSON_DIR}/{TARGET_YEAR}/{TARGET_YEAR}-{TARGET_MONTH}-{TARGET_DAY}.json"
                with open(filename, "w") as f:
                    json.dump(toc, f, indent=2)

                print(f"💾 TOC saved to {filename}")

                print("❎ Closing thumbnails panel...")

                await page.evaluate("""
                (() => {
                  const popup = document.querySelector('.thumbnail-view');
                  if (!popup) return;

                  // Try close button first
                  const closeBtn =
                    popup.querySelector('[data-role="close"], .ui-dialog-titlebar-close, .close');

                  if (closeBtn) {
                    closeBtn.click();
                    return;
                  }

                  // Fallback: hide it manually
                  popup.style.display = 'none';
                })();
                """)

                # Small pause so DOM settles

                await asyncio.sleep(5)

                current_date += timedelta(days=1)

                # There is never an edition on 25th December
                if current_date.month == 12 and current_date.day == 25:
                    current_date += timedelta(days=1)

            print("\n🟢 Script finished.")

            await context.close()
            await browser.close()

        finally:
            try:
                print("🔓 Logging out of EZproxy...")
                await page.goto("https://ezproxy.sl.nsw.gov.au/logout", timeout=15000)
                await page.wait_for_timeout(2000)
            except:
                print("⚠️ Logout skipped (already closed)")

            print("🧹 Closing browser...")
            await context.close()
            await browser.close()


if __name__ == "__main__":
    asyncio.run(main())

