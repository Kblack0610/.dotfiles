/* Copyright 2020 foostan
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */
#define TAPPING_TERM 130

#include QMK_KEYBOARD_H

const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {
[0] = LAYOUT(
     KC_TAB,    KC_Q,    KC_W,    KC_E,    KC_R,    KC_T,    KC_Y,    KC_U,     KC_I,    KC_O,   KC_P,  KC_BSPC,
     MO(3),    KC_A,    KC_S,    KC_D,    KC_F,    KC_G,    KC_H,    KC_J,     KC_K,    KC_L, KC_COLN, KC_QUOT,
     KC_LSFT,    MT(MOD_LCTL, KC_Z),    KC_X,    KC_C,    KC_V,    KC_B,    KC_N,    KC_M,  KC_COMM,  KC_DOT, KC_SLSH, KC_RSFT,
     _______, _______, MO(1), KC_LGUI,   MT(MOD_LCTL, KC_TAB),  KC_SPC,  KC_ENT,   KC_SPC,  MO(2), _______, _______, _______
  ),

[1] = LAYOUT(
    QK_BOOT, KC_7,    KC_8,    KC_E,    KC_9,    KC_9,    KC_PLUS,    KC_7,    KC_8,    KC_9,    KC_0,   KC_INS,
    KC_DEL,  KC_4,    KC_5,    KC_6,    KC_6,    KC_0,    KC_RBRC,    KC_4,    KC_5,    KC_6,    KC_PLUS, KC_PIPE,
    BL_STEP, KC_1,    KC_2,    KC_3,    KC_5,    KC_RPRN, KC_1,    KC_2,    KC_3,   KC_MINS, _______, _______,
     _______, _______, _______, _______,_______, _______,    _______, _______, _______, _______, _______, _______
),

[2] = LAYOUT(
    RGB_TOG, KC_EXLM, KC_AT,   KC_MINS, KC_UNDS, KC_PIPE,    KC_PLUS, KC_AMPR, KC_EQL,   KC_LT,   KC_GT,   KC_ASTR,
    RGB_MOD, KC_HASH, KC_DLR,  KC_LPRN, KC_RPRN, KC_GRV,     KC_EQL,  KC_LCBR, KC_RCBR,  KC_AMPR, KC_PIPE, KC_BSLS,
    KC_MUTE, KC_CIRC, KC_PERC, KC_LBRC, KC_RBRC, KC_TILD,    _______, _______,  KC_DQUO, KC_QUOT, KC_GRV,  KC_BSLS, 
     _______, _______, _______, _______,_______, _______,    _______, _______, _______, _______, _______, _______
),

[3] = LAYOUT(
    RGB_TOG, KC_EXLM, KC_AT,   KC_HASH, KC_DLR,  KC_PERC,    KC_BTN1, KC_WH_D, KC_WH_U, KC_ACL2, KC_RGHT, KC_DEL,
    RGB_MOD, KC_MPRV, KC_MNXT, KC_VOLU, KC_PSCR, KC_HOME,    KC_EQL,  KC_LEFT, KC_DOWN, KC_UP,   KC_RGHT, KC_BSLS,
    _______, KC_MSTP, KC_MPLY, KC_VOLD, KC_PGDN, KC_MINS,    KC_LPRN, _______, KC_MUTE, KC_VOLD, KC_VOLU, KC_MPLY,  
    _______, _______, _______, _______,   MO(3), _______, _______,   MO(3), _______, _______, _______, _______
),

};
