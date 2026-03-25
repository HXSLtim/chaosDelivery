// Common shader helpers for ChaosDelivery prototype effects.

#ifndef CHAOS_DELIVERY_UTILS_GDSHADERINC
#define CHAOS_DELIVERY_UTILS_GDSHADERINC

const float CHAOS_PI = 3.14159265359;
const float CHAOS_TAU = 6.28318530718;

float chaos_pulse(float speed) {
	return sin(TIME * speed * CHAOS_TAU) * 0.5 + 0.5;
}

#endif
