export const metadata = {
  title: "Tailreg Next.js fixture",
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
