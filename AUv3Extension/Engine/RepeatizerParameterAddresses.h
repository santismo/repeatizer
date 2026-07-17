#pragma once

#include <AudioToolbox/AUParameters.h>

typedef NS_ENUM(AUParameterAddress, RepeatizerParameterAddress) {
    RepeatizerParameterAddressTempoMode = 0,
    RepeatizerParameterAddressManualBPM = 1
};
