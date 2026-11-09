// Illustrated food tiles (design D14). One sprite, used with <Icon id="chicken" />.
export function IconSprite() {
  return (
    <svg width="0" height="0" style={{ position: "absolute" }} aria-hidden="true">
      <defs>
        <symbol id="i-chicken" viewBox="0 0 48 48"><path d="M30 29 40 39" stroke="#F6ECD6" strokeWidth="5" strokeLinecap="round" fill="none"/><circle cx="41" cy="38" r="3.2" fill="#F6ECD6"/><circle cx="38" cy="41.5" r="3.2" fill="#F6ECD6"/><ellipse cx="20" cy="20" rx="13.5" ry="12" fill="#E0933F"/><ellipse cx="16" cy="16" rx="6" ry="4.5" fill="#F0B56A" opacity="0.85"/></symbol>
        <symbol id="i-spinach" viewBox="0 0 48 48"><ellipse cx="16" cy="21" rx="7" ry="12" fill="#3F8F4B" transform="rotate(-25 16 21)"/><ellipse cx="32" cy="21" rx="7" ry="12" fill="#56A95F" transform="rotate(25 32 21)"/><ellipse cx="24" cy="19" rx="7" ry="13" fill="#2F7A3C"/><path d="M24 30v12" stroke="#2F7A3C" strokeWidth="3" strokeLinecap="round"/></symbol>
        <symbol id="i-bread" viewBox="0 0 48 48"><path d="M8 22c0-8 7-12 16-12s16 4 16 12v14c0 2-1 3-3 3H11c-2 0-3-1-3-3z" fill="#D9A05A"/><path d="M16 18l4 8M24 16l4 8M32 18l-1 6" stroke="#F0CC94" strokeWidth="2.4" strokeLinecap="round" fill="none"/></symbol>
        <symbol id="i-milk" viewBox="0 0 48 48"><path d="M15 14l9-6 9 6v28H15z" fill="#FFFFFF" stroke="#BDD0E6" strokeWidth="1.5"/><rect x="15" y="23" width="18" height="12" fill="#5B93D3"/></symbol>
        <symbol id="i-pasta" viewBox="0 0 48 48"><rect x="13" y="8" width="22" height="34" rx="3" fill="#E5B93C"/><path d="M18 8v10M24 8v10M30 8v10" stroke="#F3DA83" strokeWidth="2"/><rect x="16" y="18" width="16" height="12" rx="2" fill="#FFFFFF"/><rect x="13" y="34" width="22" height="5" fill="#C9372C"/></symbol>
        <symbol id="i-tuna" viewBox="0 0 48 48"><ellipse cx="24" cy="32" rx="16" ry="7" fill="#3F6FA5"/><rect x="8" y="22" width="32" height="10" fill="#4C7FB5"/><ellipse cx="24" cy="22" rx="16" ry="7" fill="#D5DDE6"/><ellipse cx="24" cy="22" rx="10" ry="4" fill="#B3C0CE"/></symbol>
        <symbol id="i-oil" viewBox="0 0 48 48"><path d="M21 6h6v8l4 5v21c0 2-1 3-3 3H20c-2 0-3-1-3-3V19l4-5z" fill="#8A9A2E"/><rect x="17" y="26" width="14" height="10" fill="#F4EFD8"/><rect x="21" y="4" width="6" height="4" rx="1" fill="#3B3F17"/></symbol>
        <symbol id="i-soap" viewBox="0 0 48 48"><rect x="15" y="20" width="18" height="22" rx="4" fill="#3FB5A8"/><rect x="20" y="12" width="8" height="8" fill="#2E8F85"/><path d="M22 12V8h10v4" stroke="#2E8F85" strokeWidth="3" fill="none" strokeLinecap="round"/><rect x="18" y="28" width="12" height="8" rx="2" fill="#E7F7F5"/></symbol>
      </defs>
    </svg>
  );
}

export function Tile({ id, bg, size = 60 }: { id: string; bg: string; size?: number }) {
  return (
    <div className="tile" style={{ width: size, height: size, background: `radial-gradient(circle at 30% 25%, #fff, ${bg} 62%)` }}>
      <svg width={size * 0.73} height={size * 0.73} viewBox="0 0 48 48" aria-hidden="true"><use href={`#i-${id}`} /></svg>
    </div>
  );
}
