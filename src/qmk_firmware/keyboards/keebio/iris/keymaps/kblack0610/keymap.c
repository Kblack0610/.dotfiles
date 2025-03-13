/* this should define the tapping term , unsure if its working*/
#define TAPPING_TERM 130
#include QMK_KEYBOARD_H

#define _QWERTY 0
#define _LOWER 1
#define _RAISE 2
#define _ADJUST 3
/* #define _GAMING 4 */

enum custom_keycodes {
  QWERTY = SAFE_RANGE,
  LOWER,
  RAISE,
  ADJUST,
  /* GAMING, */
};

const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {

  [_QWERTY] = LAYOUT(
  //┌────────┬────────┬────────┬────────┬────────┬────────┐                          ┌────────┬────────┬────────┬────────┬────────┬────────┐
     KC_ESC,  KC_1,    KC_2,    KC_3,    KC_4,    KC_5,                               KC_6,    KC_7,    KC_8,    KC_9,    KC_0,    KC_BSPC,
  //├────────┼────────┼────────┼────────┼────────┼────────┤                          ├────────┼────────┼────────┼────────┼────────┼────────┤
     KC_RALT,  KC_Q,    KC_W,    KC_E,    KC_R,    KC_T,                               KC_Y,    KC_U,    KC_I,    KC_O,    KC_P,    KC_BSPC,
  //├────────┼────────┼────────┼────────┼────────┼────────┤                          ├────────┼────────┼────────┼────────┼────────┼────────┤
     ADJUST, KC_A,    KC_S,    KC_D,    KC_F,    KC_G,                               KC_H,    KC_J,    KC_K,    KC_L,    KC_COLN, KC_QUOT,
  //├────────┼────────┼────────┼────────┼────────┼────────┼────────┐        ┌────────┼────────┼────────┼────────┼────────┼────────┼────────┤
     KC_LSFT, MT(MOD_LCTL, KC_Z), KC_X,    KC_C,    KC_V,    KC_B,    KC_HOME,          KC_ESC,  KC_N,    KC_M,    KC_COMM, KC_DOT,  KC_SLSH, KC_SCLN,
  //└────────┴────────┴────────┴───┬────┴───┬────┴───┬────┴───┬────┘        └───┬────┴───┬────┴───┬────┴───┬────┴────────┴────────┴────────┘
                                    LOWER,  KC_LGUI,   MT(MOD_LCTL, KC_TAB),     KC_ENT,  KC_SPC, RAISE
                                // └────────┴────────┴────────┘                 └────────┴────────┴────────┘
  ),

  [_LOWER] = LAYOUT(
  //┌────────┬────────┬────────┬────────┬────────┬────────┐                          ┌────────┬────────┬────────┬────────┬────────┬────────┐
     _______, _______, _______,   _______, _______,  _______,                            KC_CIRC, KC_AMPR, KC_ASTR, KC_LPRN, KC_RPRN, KC_BSPC,
  //├────────┼────────┼────────┼────────┼────────┼────────┤                          ├────────┼────────┼────────┼────────┼────────┼────────┤
     _______, _______,    KC_7,    KC_E,    KC_8,    KC_9,                               KC_PLUS,    KC_7,    KC_8,    KC_9,    KC_0, KC_INS,
  //├────────┼────────┼────────┼────────┼────────┼────────┤                          ├────────┼────────┼────────┼────────┼────────┼────────┤
     _______,  _______,    KC_4,    KC_5,    KC_6, _______,                            KC_RBRC, KC_4,    KC_5,    KC_6,   KC_PLUS, KC_PIPE,
  //├────────┼────────┼────────┼────────┼────────┼────────┼────────┐        ┌────────┼────────┼────────┼────────┼────────┼────────┼────────┤
     _______, _______,    KC_1,    KC_2,    KC_3,  _______,_______,          KC_RPRN, KC_RCBR, KC_1,    KC_2,     KC_3,   KC_MINS, _______,
  //└────────┴────────┴────────┴───┬────┴───┬────┴───┬────┴───┬────┘        └───┬────┴───┬────┴───┬────┴───┬────┴────────┴────────┴────────┘
                                    _______, _______, _______,                    KC_DEL,   ADJUST, KC_P0
                                // └────────┴────────┴────────┘                 └────────┴────────┴────────┘
  ),

  [_RAISE] = LAYOUT(
  //┌────────┬────────┬────────┬────────┬────────┬────────┐                          ┌────────┬────────┬────────┬────────┬────────┬────────┐
     KC_F12,  KC_F1,   KC_F2,   KC_F3,   KC_F4,   KC_F5,                              KC_F6,   KC_F7,   KC_F8,   KC_F9,   KC_F10,  KC_F11,
  //├────────┼────────┼────────┼────────┼────────┼────────┤                          ├────────┼────────┼────────┼────────┼────────┼────────┤
     RGB_TOG, KC_EXLM, KC_AT,   KC_MINS, KC_UNDS,  KC_PIPE,                            KC_PLUS, KC_AMPR, KC_EQL, KC_LT,   KC_GT,   KC_ASTR,
  //├────────┼────────┼────────┼────────┼────────┼────────┤                          ├────────┼────────┼────────┼────────┼────────┼────────┤
     RGB_MOD, KC_HASH, KC_DLR, KC_LPRN, KC_RPRN,   KC_GRV,                            KC_EQL,  KC_LCBR, KC_RCBR, KC_AMPR, KC_PIPE, KC_BSLS,
  //├────────┼────────┼────────┼────────┼────────┼────────┼────────┐        ┌────────┼────────┼────────┼────────┼────────┼────────┼────────┤
     KC_MUTE, KC_CIRC, KC_PERC, KC_LBRC, KC_RBRC, KC_TILD, KC_HOME,          _______,  _______, KC_DQUO,  KC_QUOT, KC_GRV, KC_BSLS, _______,
  //└────────┴────────┴────────┴───┬────┴───┬────┴───┬────┴───┬────┘        └───┬────┴───┬────┴───┬────┴───┬────┴────────┴────────┴────────┘
                                    KC_S, ADJUST,  KC_LALT,                   _______, _______, _______
                                // └────────┴────────┴────────┘                 └────────┴────────┴────────┘
  ),

  [_ADJUST] = LAYOUT(
  //┌────────┬────────┬────────┬────────┬────────┬────────┐                          ┌────────┬────────┬────────┬────────┬────────┬────────┐
     KC_F12,  KC_F1,   KC_F2,   KC_F3,   KC_F4,   KC_F5,                              KC_F6,   KC_F7,   KC_F8,   KC_F9,   KC_F10,  KC_F11,
  //├────────┼────────┼────────┼────────┼────────┼────────┤                          ├────────┼────────┼────────┼────────┼────────┼────────┤
     RGB_TOG, KC_EXLM, KC_AT,   KC_HASH, KC_DLR,  KC_PERC,                            KC_BTN1, KC_WH_D, KC_WH_U, KC_ACL2, KC_RGHT, KC_DEL,
  //├────────┼────────┼────────┼────────┼────────┼────────┤                          ├────────┼────────┼────────┼────────┼────────┼────────┤
     RGB_MOD, KC_MPRV, KC_MNXT, KC_VOLU, KC_PSCR, KC_HOME,                            KC_EQL,  KC_LEFT, KC_DOWN, KC_UP,   KC_RGHT, KC_BSLS,
  //├────────┼────────┼────────┼────────┼────────┼────────┼────────┐        ┌────────┼────────┼────────┼────────┼────────┼────────┼────────┤
     _______, KC_MSTP, KC_MPLY, KC_VOLD, KC_PGDN, KC_MINS, KC_LPRN,          _______, KC_PLUS, KC_VOLD,  KC_VOLU, KC_MPLY, RGB_VAD, _______,
  //└────────┴────────┴────────┴───┬────┴───┬────┴───┬────┴───┬────┘        └───┬────┴───┬────┴───┬────┴───┬────┴────────┴────────┴────────┘
                                    _______, KC_SPC,  KC_ENT,                   _______, _______, _______
                                // └────────┴────────┴────────┘                 └────────┴────────┴────────┘
 ),

 /* [_GAMING] = LAYOUT( */
 /*  //┌────────┬────────┬────────┬────────┬────────┬────────┐                          ┌────────┬────────┬────────┬────────┬────────┬────────┐ */
 /*     KC_ESC,  KC_1,    KC_2,    KC_3,    KC_4,    KC_5,                               KC_6,    KC_7,    KC_8,    KC_9,    KC_0,    KC_BSPC, */
 /*  //├────────┼────────┼────────┼────────┼────────┼────────┤                          ├────────┼────────┼────────┼────────┼────────┼────────┤ */
 /*     KC_TAB,  KC_Q,    KC_W,    KC_E,    KC_R,    KC_T,                               KC_Y,    KC_U,    KC_I,    KC_O,    KC_P,    KC_DEL, */
 /*  //├────────┼────────┼────────┼────────┼────────┼────────┤                          ├────────┼────────┼────────┼────────┼────────┼────────┤ */
 /*     ADJUST, KC_A,    KC_S,    KC_D,    KC_F,    KC_G,                               KC_H,    KC_J,    KC_K,    KC_L,    KC_COLN, KC_QUOT, */
 /*  //├────────┼────────┼────────┼────────┼────────┼────────┼────────┐        ┌────────┼────────┼────────┼────────┼────────┼────────┼────────┤ */
 /*     KC_LSFT, MT(MOD_LCTL, KC_Z), KC_X,    KC_C,    KC_V,    KC_B,    KC_HOME,          KC_ESC,  KC_N,    KC_M,    KC_COMM, KC_DOT,  KC_SLSH, KC_SCLN, */
 /*  //└────────┴────────┴────────┴───┬────┴───┬────┴───┬────┴───┬────┘        └───┬────┴───┬────┴───┬────┴───┬────┴────────┴────────┴────────┘ */
 /*                                    KC_LGUI,  KC_SPC,   MOD_LCTL,     KC_ENT,  KC_SPC , TO(QWERTY) */
 /*                                // └────────┴────────┴────────┘                 └────────┴────────┴────────┘ */
 /*  ), */

};

/*  bool encoder_update_user(uint8_t index, bool clockwise) { */
/*     if (index == 0) {               // Index 0 is the first encoder */
/*         if (clockwise) { */
/*             tap_code(KC_WH_D);      // Page Down is sent if the 2nd encoder is rotated clockwise */
/*         } else { */
/*             tap_code(KC_WH_U);      // Page Up is sent if the 2nd encoder is rotated counter-clockwise */
/*         } */
/*     } */
/*     else if (index == 1) {          // Index 1 is the second encoder */
/*         if (clockwise) { */
/*             tap_code(KC_PGDN);      // Page Down is sent if the 2nd encoder is rotated clockwise */
/*         } else { */
/*             tap_code(KC_PGUP);      // Page Up is sent if the 2nd encoder is rotated counter-clockwise */
/*         } */
/*     } */
/**/
/*     // If you have more encoders, add more `else if (index == ...)` blocks here */
/**/
/*     return false; */
/* } */
/**/
/* bool process_record_user(uint16_t keycode, keyrecord_t *record) { */
/*   switch (keycode) { */
/*     case qwerty: */
/*       if (record->event.pressed) { */
/*         set_single_persistent_default_layer(_qwerty); */
/*       } */
/*       return false; */
/*       break; */
/*     case lower: */
/*       if (record->event.pressed) { */
/*         layer_on(_lower); */
/*         update_tri_layer(_lower, _raise, _adjust); */
/*       } else { */
/*         layer_off(_lower); */
/*         update_tri_layer(_lower, _raise, _adjust); */
/*       } */
/*       return false; */
/*       break; */
/*     case raise: */
/*       if (record->event.pressed) { */
/*         layer_on(_raise); */
/*         update_tri_layer(_lower, _raise, _adjust); */
/*       } else { */
/*         layer_off(_raise); */
/*         update_tri_layer(_lower, _raise, _adjust); */
/*       } */
/*       return false; */
/*       break; */
/*     case adjust: */
/*       if (record->event.pressed) { */
/*         layer_on(_adjust); */
/*       } else { */
/*         layer_off(_adjust); */
/*       } */
/*       return false; */
/*      case gaming: */
/*       if (record->event.pressed) { */
/*         layer_on(_adjust); */
/*       } else { */
/*         layer_off(_adjust); */
/*       } */
/*       return false; */
/*       break; break; */
/*   } */
/*   return true; */
/* } */
bool process_record_user(uint16_t keycode, keyrecord_t *record) {
  switch (keycode) {
    case QWERTY:
      if (record->event.pressed) {
        set_single_persistent_default_layer(_QWERTY);
      }
      return false;
      break;
    case LOWER:
      if (record->event.pressed) {
        layer_on(_LOWER);
        update_tri_layer(_LOWER, _RAISE, _ADJUST);
      } else {
        layer_off(_LOWER);
        update_tri_layer(_LOWER, _RAISE, _ADJUST);
      }
      return false;
      break;
    case RAISE:
      if (record->event.pressed) {
        layer_on(_RAISE);
        update_tri_layer(_LOWER, _RAISE, _ADJUST);
      } else {
        layer_off(_RAISE);
        update_tri_layer(_LOWER, _RAISE, _ADJUST);
      }
      return false;
      break;
    case ADJUST:
      if (record->event.pressed) {
        layer_on(_ADJUST);
      } else {
        layer_off(_ADJUST);
      }
      return false;
      break;
     /* case GAMING: */
     /*  if (record->event.pressed) { */
     /*    layer_on(_ADJUST); */
     /*  } else { */
     /*    layer_off(_ADJUST); */
     /*  } */
     /*  return false; */
     /*  break; break; */
  }
  return true;
}
