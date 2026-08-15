import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { headers } from "next/headers";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") || requestHeaders.get("host") || "localhost:3000";
  const protocol = requestHeaders.get("x-forwarded-proto") || (host.includes("localhost") ? "http" : "https");
  const origin = `${protocol}://${host}`;

  return {
    metadataBase: new URL(origin),
    title: "TwoK TOOLS — DNS, SSL & Domain Intelligence",
    description: "Bộ công cụ kiểm tra DNS, SSL, tên miền, HTTP headers và bảo mật email trực tiếp, nhanh và rõ ràng.",
    icons: {
      icon: "/favicon.svg",
      shortcut: "/favicon.svg",
    },
    openGraph: {
      type: "website",
      locale: "vi_VN",
      url: origin,
      siteName: "TwoK TOOLS",
      title: "TwoK TOOLS — DNS, SSL & Domain Intelligence",
      description: "Mọi tín hiệu hạ tầng trong một lần kiểm tra.",
      images: [{ url: `${origin}/og-twok.png`, width: 1731, height: 909, alt: "TwoK TOOLS — DNS, SSL & Domain Intelligence" }],
    },
    twitter: {
      card: "summary_large_image",
      title: "TwoK TOOLS — DNS, SSL & Domain Intelligence",
      description: "Mọi tín hiệu hạ tầng trong một lần kiểm tra.",
      images: [`${origin}/og-twok.png`],
    },
  };
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="vi">
      <body className={`${geistSans.variable} ${geistMono.variable}`}>{children}</body>
    </html>
  );
}
