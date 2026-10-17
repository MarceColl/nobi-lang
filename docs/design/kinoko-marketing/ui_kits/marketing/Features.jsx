import React from 'react';
import { FeatureCard } from '../../components/surfaces/FeatureCard.jsx';
import { SectionHead } from './SectionHead.jsx';

const FEATURES = [
  { variant: 'sprout', hue: '#7DD3C0', title: 'Strong type system', description: 'Catch errors at definition time, not runtime. The type checker verifies correctness before code ever runs.' },
  { variant: 'spore', hue: '#B8A5D9', title: 'Simulation testing', description: 'Run thousands of scenarios in a sandbox that behaves exactly like production. Find edge cases before users do.' },
  { variant: 'glow', hue: '#F5C869', title: 'Reproducible execution', description: 'Every request can be replayed exactly. When something fails, recreate the exact conditions and debug it.' },
];

export function Features() {
  return (
    <section id="features" style={{ position: 'relative', padding: '96px 32px' }}>
      <div style={{ maxWidth: 'var(--measure)', margin: '0 auto' }}>
        <SectionHead title="Trust through constraints" width="500px" gap={64}>
          The bottleneck isn't writing code—it's trusting code. System constraints raise quality so speed can follow.
        </SectionHead>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))', gap: 24 }}>
          {FEATURES.map(f => <FeatureCard key={f.title} {...f} />)}
        </div>
      </div>
    </section>
  );
}
