# Portkeep

**เปิด port forward ค้างไว้ได้ตลอด จาก menu bar**

Portkeep เป็นแอป menu bar บน macOS สำหรับ tunnel ที่ต้องเปิดทุกวัน เช่น ฐานข้อมูล, cache, dashboard หรือ SOCKS proxy ที่อยู่หลัง SSH jump host, AWS Session Manager, Kubernetes และอื่น ๆ ตั้งชื่อ tunnel ครั้งเดียว กดเปิดได้ในคลิกเดียว แล้ว Portkeep จะคอยดูแลให้ต่ออยู่ ถ้าหลุดจะบอกว่าตัวไหน เพราะอะไร และกำลังต่อใหม่ให้อยู่

[English](README.md)

<p align="center">
  <img src="docs/images/menu-th-light.png" width="320" alt="เมนู Portkeep ภาษาไทย">
  &nbsp;&nbsp;
  <img src="docs/images/settings-th-light.png" width="480" alt="หน้าต่างการตั้งค่า ภาษาไทย">
</p>

## ทำอะไรได้

- **หนึ่งสวิตช์ต่อหนึ่ง tunnel** จัดกลุ่มตาม environment (UAT, Production …) พร้อมเลขพอร์ตในเครื่อง
- **สถานะตรงความจริง** ขึ้นว่าเชื่อมต่อแล้วก็ต่อเมื่อพอร์ตในเครื่องรับการเชื่อมต่อได้จริง ไม่ใช่แค่ process ยังรันอยู่
- **ต่อใหม่อัตโนมัติ** หลังเครื่องหลับ เปลี่ยน Wi-Fi หรือ session หลุด เว้นระยะ 1 วินาทีไล่ไปถึง 60 วินาที และไม่นับรอบตอนออฟไลน์
- **บอกสาเหตุชัด ๆ** เช่น host key เปลี่ยน, AWS SSO หมดอายุ, พอร์ตถูก process อื่นใช้อยู่ พร้อมปุ่มแก้ในคลิกเดียว
- **กันพอร์ตชน** เช็กพอร์ตก่อนเริ่ม บอกชื่อ process ที่จองอยู่ และเสนอพอร์ตที่ว่างให้

## วิธีเชื่อมต่อที่รองรับ

SSH (`-L` / `-R` / `-D`, ProxyJump), AWS SSM `start-session`, `kubectl port-forward`, Google Cloud IAP, Cloudflare Access และคำสั่งกำหนดเองที่เปิดพอร์ตค้างไว้ Portkeep เรียกเครื่องมือที่คุณใช้อยู่แล้ว ใช้ config และ credential เดิม และแสดงคำสั่งจริงที่จะรัน ไม่เก็บรหัสผ่าน คีย์ หรือ token ใด ๆ

## ติดตั้ง

ต้องใช้ macOS 14 Sonoma ขึ้นไป

- **ดาวน์โหลด**: เวอร์ชันที่ notarize แล้วจะอยู่ที่หน้า [Releases](https://github.com/rattamnoon/portkeep/releases) *(ยังไม่มี)*
- **Homebrew** (เมื่อออกเวอร์ชันแรก): `brew install --cask rattamnoon/tap/portkeep`
- **Build เอง**:

```
brew install xcodegen
git clone https://github.com/rattamnoon/portkeep.git && cd portkeep
xcodegen generate
xcodebuild -scheme Portkeep -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Portkeep.app
```

## วิธีใช้

1. คลิกไอคอนรูปซุ้มประตูที่ menu bar แล้วเลือก **เพิ่ม Tunnel…**
2. เลือกวิธีเชื่อมต่อ กรอกข้อมูล (host, โปรไฟล์ AWS และ kube context ที่มีอยู่จะขึ้นให้เลือก) แล้วเลือกพอร์ตในเครื่อง กล่อง **คำสั่งที่จะรัน** จะแสดงคำสั่งจริง
3. กด **ทดสอบการเชื่อมต่อ** แล้วกด **เพิ่ม Tunnel**
4. คลิก tunnel ในเมนูเพื่อเปิด/ปิด สวิตช์ด้านบนใช้เปิด/ปิดทั้งหมด
5. เปิด **เชื่อมต่อเมื่อเข้าสู่ระบบ** สำหรับ tunnel ที่ต้องใช้ตลอด

เปลี่ยนภาษาได้ที่ **การตั้งค่า › ทั่วไป › ภาษา** (อังกฤษ, ไทย, จีนตัวย่อ, ญี่ปุ่น)

## ข้อจำกัดของเวอร์ชันนี้

- ยังไม่รองรับการพิมพ์รหัสผ่าน, passphrase หรือ OTP ให้เพิ่มคีย์เข้า agent ด้วย `ssh-add --apple-use-keychain` ก่อน
- ยังไม่มี sync ข้ามเครื่อง และ import/export
- ไม่ขึ้น Mac App Store เพราะ sandbox ทำให้เรียกเครื่องมือและอ่าน config ของคุณไม่ได้
