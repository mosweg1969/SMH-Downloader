#!/usr/bin/env python3

import asyncio
from playwright.async_api import async_playwright
from datetime import date, datetime
import json
import argparse
import os
import requests

# ========== CONFIG ==========
EZ_EMAIL = "mosweg1969@gmail.com"
EZ_PASSWORD = "5731StateLibraryNSW!"

EZPROXY_URL = "https://ezproxy.sl.nsw.gov.au/login?qurl=https%3A//www.libraryedition.com.au/truetoprint/fnc_login_network.php"
JSON_DIR = "/mnt/storage/Newspapers/The Sydney Morning Herald/Contents"

BASE_IMAGE_URL = "https://libraryedition.smedia.com.au/lib_s/get/image.ashx"
NEWSPAPER_CODE = "SMH"


async def export_cookies_to_requests(context):
    cookies = await context.cookies()
    session = requests.Session()

    for c in cookies:
        session.cookies.set(
            name=c["name"],
            value=c["value"],
            domain=c["domain"],
            path=c["path"],
        )

    return session


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


async def download_pages(session, date_str, total_pages):
    dt = datetime.strptime(date_str, "%Y-%m-%d")
    year = dt.strftime("%Y")
    month = dt.strftime("%m")
    day = dt.strftime("%d")

    output_dir = f"/mnt/storage/Newspapers/The Sydney Morning Herald/Editions/{year}/{date_str}/Pages"

    href_base = f"{NEWSPAPER_CODE}/{year}/{month}/{day}"

    os.makedirs(output_dir, exist_ok=True)

    print(f"📅 Downloading {total_pages} pages for {href_base}")
    print(f"📂 Saving to {output_dir}\n")

    for page in range(1, total_pages + 1):
        params = {
            "kind": "page",
            "href": href_base,
            "page": str(page),
        }

        filename = f"{NEWSPAPER_CODE}_{date_str}_p{page:03}.png"
        filepath = os.path.join(output_dir, filename)

        print(f"⬇️  Page {page}/{total_pages} → {filename}")

        response = session.get(BASE_IMAGE_URL, params=params, timeout=30)

        if response.status_code != 200:
            print(f"⚠️  Failed page {page}: HTTP {response.status_code}")
            continue

        with open(filepath, "wb") as f:
            f.write(response.content)

    print("\n✅ Download complete")


async def main():
    parser = argparse.ArgumentParser(description="Download SMH edition images")
    parser.add_argument("-date", required=True, help="Edition date (YYYY-MM-DD)")
    parser.add_argument("-pages", required=True, type=int, help="Total number of pages")

    args = parser.parse_args()
    
    try:
        target_date = datetime.strptime(args.date, "%Y-%m-%d")
    except ValueError:
        raise SystemExit("❌ Date must be in YYYY-MM-DD format")

    print(f"Extracting pages for {target_date}")

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
            
            print("🔐 Exporting session cookies...")
            session = await export_cookies_to_requests(context)

            await download_pages(session, args.date, args.pages)
            
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
