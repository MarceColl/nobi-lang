import React from 'react';
import { WindowChrome } from '../../components/surfaces/WindowChrome.jsx';
import { TerminalLine } from '../../components/console/TerminalLine.jsx';

export function TerminalDemo() {
  return (
    <div style={{ marginTop: 80, position: 'relative' }}>
      <div style={{
        position: 'absolute', inset: -20, zIndex: -1,
        background: 'radial-gradient(ellipse at center, rgba(125,211,192,0.15) 0%, transparent 70%)',
        filter: 'blur(40px)',
      }} />
      <WindowChrome title="kinoko — universe:main" style={{ boxShadow: 'var(--glow-violet), var(--inset-hairline)' }}>
        <div style={{ padding: '0 24px 24px' }}>
          <TerminalLine speaker="you">Add a user authentication system with sessions</TerminalLine>
          <TerminalLine speaker="pm">Updating theory with Principal abstraction... Creating epic with 4 tasks...</TerminalLine>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            <TerminalLine indent tone="ok" label="Theory evolved" note="Principal, Session types added" />
            <TerminalLine indent tone="ok" label="Bindings compiled" note="12 functions, all typecheck" />
            <TerminalLine indent tone="ok" label="Effects verified" note="deterministic under simulation" />
            <TerminalLine indent tone="running" label="Property testing edge cases..." />
          </div>
        </div>
      </WindowChrome>
    </div>
  );
}
