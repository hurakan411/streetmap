# Street Print — App Store release draft

## Product identity

- App name: Street Print
- Subtitle: Your Personal Route Map
- Bundle ID: `jp.michi.walkmap`
- Version / build: `1.0 (1)` — confirm final release numbering before upload
- Platforms: iPhone and iPad (iOS 17+)
- Category: Lifestyle (confirm)
- Price / availability: Free; worldwide (confirmed by the user)

## Japanese listing

### Promotional text

歩いた道が、あなたの地図になる。いつもの街に残る、まだ知らない道を見つけよう。

### Description

Street Printは、日々の移動を地図に重ねて、自分だけの街の記録をつくるアプリです。

歩いた道を振り返りながら、初めて通った道や移動距離、記録した日数をチェック。地図を見て、次の散歩で歩いてみたい道を見つけましょう。

• 移動経路を自動で記録（位置情報の許可と記録モードに応じて動作）
• 期間を「今日・今月・今年・すべて」から選択
• 新しい道、移動距離、アクティブ日数を表示
• 地図のスタイルをカスタマイズ
• 地図あり／経路のみの表示を切り替え
• 現在の表示を画像として共有

記録履歴は端末内に保存されます。道路への経路補正にはApple MapKitを使用します。位置情報の使用範囲は設定から変更でき、記録履歴はいつでも削除できます。

### Keywords (draft, 100 characters max)

散歩,地図,歩数,ルート,街歩き,旅行,記録,ウォーキング

## English listing

### Promotional text

Your walks, drawn on your map. Discover the streets you have yet to explore.

### Description

Street Print turns your everyday routes into a personal map of the places you know—and the streets still waiting to be explored.

Look back at the roads you have traveled, see which ones are new, and find an idea for your next walk.

• Automatically record movement, based on your location permissions and recording settings
• Explore your map by day, month, year, or all time
• See new roads, distance traveled, and active days
• Choose a visual map style
• Switch between the map and route-only views
• Share an image of the view on screen

Route history is stored on your device. Apple MapKit is used for map display and road matching. You can change location access in Settings and delete your history at any time.

### Keywords (draft, 100 characters max)

walking,walk,map,routes,city,explore,tracker,travel

## Required before submission

- Privacy policy URL supplied by the user: `https://spiffy-otter-353150.netlify.app/` — inspected; it is a “Sample Gallery” page whose policy covers unrelated escape-game apps, says precise location is not collected, and describes advertising SDKs. Do not use this URL for Street Print until it is replaced with an accurate Street Print policy.
- Support URL supplied by the user: `https://docs.google.com/forms/d/e/1FAIpQLSc7bq_M2ZAEy82aEmp6kgI8TYWsKSADh3LD4vk8nrXRsp9RLg/viewform` — inspected; it is titled “Obeyne | AI Task Manager” and asks for feedback for that app. Do not use this URL for Street Print.
- Provide a Street Print-specific privacy-policy page and support/contact page (or support form) that actually identifies Street Print and provides a way to reach the developer. The in-app policy currently has a placeholder contact statement and should be updated before launch.
- Confirm the newly created App Store Connect app record's Bundle ID is `jp.michi.walkmap`.
- Confirm listing locale, category, price, territories, age rating, copyright holder, and any content-rights answers.
- Upload localized screenshots for supported device sizes. Do not use simulator demo data in screenshots unless clearly representative; simulator-only fixtures are compiled out of Release.
- Complete App Privacy disclosures, including reviewing how Apple MapKit handles location/route requests. Do not submit a “no data collected” answer until that is verified against the actual data flow and Apple's definitions.
- Test the Release build on a physical device: onboarding, foreground/background/always location modes, route persistence/deletion, share flows, and permission-denied states. A Release build has been installed and launched on iPhone 13, but this full test matrix remains.
- Supply App Review notes explaining that the app records movement only after the user opts into a recording mode, and provide steps for testing without demo credentials.
- Verify archive signing with the active Apple Developer team, then upload through Xcode Organizer or Transporter and submit from App Store Connect.

## Current local validation

- Release configuration build (`Release`, optimized) was installed and launched on the paired iPhone 13 on 2026-10-12. It uses Apple Development signing for device testing, not App Store distribution signing.
- The existing local archive is `build/AppStoreRelease.xcarchive`, version 1.0 (1), and is Apple Development-signed. Do not upload this archive as-is.
- A separately exported App Store IPA exists at `/private/tmp/MichiAppStoreExport/Michi.ipa`; it was previously verified with Apple Distribution signing for Team `9927M765H2`. Confirm it matches the final source before uploading.
- A fresh distribution archive attempt was rejected because the Xcode target's automatic signing conflicts with a command-line identity override. Avoid changing signing mode or provisioning settings without checking the project/team setup in Xcode.
- Privacy manifest and English permission prompt strings are included in the Release app bundle.

## App Review notes (draft)

Street Print is a personal route-map app. It does not require an account. Location recording is controlled in Settings and can be disabled at any time. Map display and road matching use Apple MapKit. To review the app, grant location access, select a recording mode, then use the map, period controls, route-only view, settings, and share action. The app includes no subscription or in-app purchase.

## Open decisions

- Street Print-specific public privacy-policy URL and support/contact URL
- Contact address to include in the support page and privacy policy
- Final screenshots; confirm the App Store Connect record uses Bundle ID `jp.michi.walkmap`
- App Privacy label classification for MapKit location processing
