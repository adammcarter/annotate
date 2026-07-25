import React from 'react';
import { Composition } from 'remotion';
import { Tools, DURATION, FPS } from './Tools';

export const RemotionRoot: React.FC = () => (
  <Composition
    id="Tools"
    component={Tools}
    durationInFrames={DURATION}
    fps={FPS}
    width={1470}
    height={700}
  />
);
