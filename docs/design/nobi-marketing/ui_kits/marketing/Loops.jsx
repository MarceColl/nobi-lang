import React from 'react';
import { SectionHead } from './SectionHead.jsx';

/* The source's fifth section. Its heading and lead are verbatim; the diagram
   itself (LoopsWithinLoops — ~400 lines of hand-placed SVG in App.tsx) is a
   bespoke illustration rather than a reusable component, so the frame is left
   labeled and empty instead of reproduced or approximated. */
export function Loops() {
  const stages = [
    ['Exploration', '#B8A5D9', 'Human ↔ Agent'],
    ['Development', '#7DD3C0', 'Agent ↔ Code ↔ Human'],
    ['Validation', '#9FEDD7', 'Human ↔ Staging ↔ Agent ↔ Simulation'],
    ['Production', '#F5C869', 'Errors → Agent → Fix → Human'],
  ];

  return (
    <section style={{ position: 'relative', padding: '96px 32px' }}>
      <div style={{ maxWidth: 1000, margin: '0 auto' }}>
        <SectionHead title="Tighter loops at every stage">
          The more information an agent has, the fewer mistakes it makes. At every stage of development, tight feedback loops keep agents informed and iterations fast.
        </SectionHead>

        <div style={{
          border: '1px dashed rgba(139,123,181,0.25)',
          borderRadius: 'var(--radius-xl)',
          padding: 32,
          display: 'flex', flexDirection: 'column', gap: 20, alignItems: 'center',
        }}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: 16, width: '100%' }}>
            {stages.map(([name, color, loop]) => (
              <div key={name} style={{
                background: color + '10',
                border: '1px solid ' + color + '30',
                borderRadius: 'var(--radius-xl)',
                padding: 20,
              }}>
                <div style={{ fontFamily: 'var(--font-display)', fontSize: 18, fontWeight: 600, color, marginBottom: 8 }}>{name}</div>
                <div style={{ fontSize: 12, color: 'var(--kn-text-dim)', fontFamily: 'var(--font-mono)' }}>{loop}</div>
              </div>
            ))}
          </div>
          <div style={{ fontSize: 12, color: 'var(--kn-text-faint)', textAlign: 'center', maxWidth: 480, lineHeight: 1.6 }}>
            The source renders these four stages as one large dashed cycle with a nested
            loop at each node. That illustration is not reproduced here — see the kit README.
          </div>
        </div>
      </div>
    </section>
  );
}
