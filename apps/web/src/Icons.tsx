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
        <symbol id="i-egg" viewBox="0 0 48 48"><ellipse cx="19" cy="27" rx="9" ry="12" fill="#FBF3E4" stroke="#E8D6B8" strokeWidth="1.5"/><ellipse cx="30" cy="25" rx="9" ry="12" fill="#F3DDBD" stroke="#E0C29A" strokeWidth="1.5"/><ellipse cx="27" cy="20" rx="3" ry="4" fill="#FFF8EC" opacity=".8"/></symbol>
        <symbol id="i-fish" viewBox="0 0 48 48"><path d="M6 24c6-9 16-11 26-6l8-6v24l-8-6C22 35 12 33 6 24z" fill="#E98B6D"/><path d="M14 24c4-4 10-5 16-3" stroke="#F7C1A9" strokeWidth="2.5" fill="none" strokeLinecap="round"/><circle cx="13" cy="22" r="1.8" fill="#4A2A20"/></symbol>
        <symbol id="i-apple" viewBox="0 0 48 48"><path d="M24 15c-3-3-12-3-14 5-2 9 4 20 9 20 2 0 3-1 5-1s3 1 5 1c5 0 11-11 9-20-2-8-11-8-14-5z" fill="#D9473B"/><path d="M24 15c0-4 2-7 5-8" stroke="#6B4423" strokeWidth="2.5" fill="none" strokeLinecap="round"/><ellipse cx="31" cy="10" rx="5" ry="2.6" fill="#5FA84B" transform="rotate(-25 31 10)"/><ellipse cx="17" cy="21" rx="3" ry="5" fill="#EE7A6E" opacity=".7"/></symbol>
        <symbol id="i-cheese" viewBox="0 0 48 48"><path d="M6 30 30 12l12 6v16H6z" fill="#F4C64E"/><path d="M6 30h36v6H6z" fill="#E3AE2F"/><circle cx="20" cy="28" r="2.6" fill="#E3AE2F"/><circle cx="31" cy="22" r="2" fill="#E3AE2F"/><circle cx="34" cy="30" r="1.6" fill="#E3AE2F"/></symbol>
        <symbol id="i-pot" viewBox="0 0 48 48"><path d="M17 14c0-3 2-4 2-6M24 14c0-3 2-4 2-6M31 14c0-3 2-4 2-6" stroke="#C9B9A6" strokeWidth="2" fill="none" strokeLinecap="round"/><rect x="8" y="19" width="32" height="4" rx="2" fill="#7A4E35"/><path d="M10 23h28v12c0 4-3 6-7 6H17c-4 0-7-2-7-6z" fill="#B8654A"/><path d="M4 26h6M38 26h6" stroke="#7A4E35" strokeWidth="3" strokeLinecap="round"/></symbol>
        <symbol id="i-snow" viewBox="0 0 48 48"><g stroke="#4D8FC9" strokeWidth="3.2" strokeLinecap="round"><path d="M24 7v34M9 15.5l30 17M9 32.5l30-17"/><path d="M19 9l5 4 5-4M19 39l5-4 5 4" fill="none"/></g><circle cx="24" cy="24" r="4" fill="#A9CDEB"/></symbol>
        <symbol id="i-fridge" viewBox="0 0 48 48"><rect x="12" y="5" width="24" height="38" rx="4" fill="#F7FAFB" stroke="#9FB4BF" strokeWidth="2"/><path d="M12 19h24" stroke="#9FB4BF" strokeWidth="2"/><path d="M17 11v4M17 24v6" stroke="#6E8794" strokeWidth="2.6" strokeLinecap="round"/></symbol>
        <symbol id="i-cupboard" viewBox="0 0 48 48"><rect x="7" y="9" width="34" height="32" rx="3" fill="#C8955F"/><path d="M24 9v32" stroke="#8E623A" strokeWidth="2"/><circle cx="21" cy="25" r="1.8" fill="#5B3E24"/><circle cx="27" cy="25" r="1.8" fill="#5B3E24"/><rect x="7" y="6" width="34" height="5" rx="2" fill="#8E623A"/></symbol>
        <symbol id="i-coffee" viewBox="0 0 48 48"><path d="M10 18h24v12c0 6-5 10-12 10s-12-4-12-10z" fill="#FFFFFF" stroke="#C9B9A6" strokeWidth="1.5"/><path d="M34 21h3a4 4 0 0 1 0 8h-3" stroke="#C9B9A6" strokeWidth="3" fill="none"/><ellipse cx="22" cy="19" rx="11" ry="2.5" fill="#6B4423"/><path d="M18 8c0 3 3 3 3 6M25 8c0 3 3 3 3 6" stroke="#C9B9A6" strokeWidth="2" fill="none" strokeLinecap="round"/></symbol>
        <symbol id="i-bottle" viewBox="0 0 48 48"><path d="M20 5h8v9c4 2 6 5 6 9v17c0 2-1 3-3 3H17c-2 0-3-1-3-3V23c0-4 2-7 6-9z" fill="#5E9BC8"/><rect x="14" y="25" width="20" height="9" fill="#EAF3FA"/><rect x="20" y="3" width="8" height="4" rx="1" fill="#2F5D80"/></symbol>
        <symbol id="i-receipt" viewBox="0 0 48 48"><path d="M12 5h24v38l-4-3-4 3-4-3-4 3-4-3-4 3z" fill="#FFFFFF" stroke="#BFB6A4" strokeWidth="1.5"/><path d="M17 14h14M17 20h14M17 26h9" stroke="#8C8472" strokeWidth="2.4" strokeLinecap="round"/><path d="M27 32h4" stroke="#234032" strokeWidth="3" strokeLinecap="round"/></symbol>
        <symbol id="i-spark" viewBox="0 0 48 48"><path d="M24 4c1.5 9 5 12.5 14 14-9 1.5-12.5 5-14 14-1.5-9-5-12.5-14-14 9-1.5 12.5-5 14-14z" fill="#E3C47A"/><path d="M37 28c.7 4 2.3 5.6 6 6-3.7.7-5.3 2.3-6 6-.7-3.7-2.3-5.3-6-6 3.7-.4 5.3-2 6-6z" fill="#F3E2B5"/></symbol>
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
