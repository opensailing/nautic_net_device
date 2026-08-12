NIF_NAME := outbox_segment

ifeq ($(strip $(MIX_APP_PATH)),)
$(error MIX_APP_PATH is not set; invoke this Makefile through Mix)
endif

ifeq ($(strip $(MIX_TARGET)),)
$(error MIX_TARGET is not set; invoke this Makefile through Mix)
endif

ifeq ($(strip $(ERTS_INCLUDE_DIR)),)
$(error ERTS_INCLUDE_DIR is not set; invoke this Makefile through Mix)
endif

PRIV_DIR := $(MIX_APP_PATH)/priv/native/$(MIX_TARGET)
OBJ_DIR := $(MIX_APP_PATH)/obj/native/$(MIX_TARGET)
NIF := $(PRIV_DIR)/$(NIF_NAME).so
OBJ := $(OBJ_DIR)/outbox_segment.o

CPPFLAGS += -I"$(ERTS_INCLUDE_DIR)"
CFLAGS += -std=c11 -fPIC -Wall -Wextra -Wpedantic

ifeq ($(WERROR),1)
CFLAGS += -Werror
endif

ifeq ($(MIX_TARGET),host)
  ifeq ($(shell uname -s),Darwin)
    NIF_LDFLAGS := -bundle -undefined dynamic_lookup
  else
    NIF_LDFLAGS := -shared
  endif
else
  NIF_LDFLAGS := -shared
endif

all: $(NIF)

$(NIF): $(OBJ) | $(PRIV_DIR)
	$(CC) -o "$@" $^ $(LDFLAGS) $(NIF_LDFLAGS) $(LDLIBS)

$(OBJ): outbox_segment.c Makefile | $(OBJ_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c -o "$@" "$<"

$(PRIV_DIR) $(OBJ_DIR):
	mkdir -p "$@"

clean:
	$(RM) "$(NIF)"
	$(RM) -r "$(OBJ_DIR)"
	rmdir "$(PRIV_DIR)" 2>/dev/null || true

.PHONY: all clean
.DELETE_ON_ERROR:
