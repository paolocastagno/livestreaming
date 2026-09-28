.PHONY: help prepare prepare-gpu build build-gpu up up-gpu gpu-check down status check profile-fiber profile-5g profile-4g profile-dsl profile-congested profile-3g profile-bad traffic-off traffic-light traffic-medium traffic-heavy clean-media

help:
	@./labctl help

prepare:
	@./labctl prepare cpu

prepare-gpu:
	@./labctl prepare gpu

build:
	@./labctl build cpu

build-gpu:
	@./labctl build gpu

up:
	@./labctl up cpu

up-gpu:
	@./labctl up gpu

gpu-check:
	@./labctl gpu-check

down:
	@./labctl down

status:
	@./labctl status

check:
	@./labctl check

profile-fiber profile-5g profile-4g profile-dsl profile-congested profile-3g profile-bad:
	@./labctl profile $(@:profile-%=%)

traffic-off traffic-light traffic-medium traffic-heavy:
	@./labctl traffic $(@:traffic-%=%)

clean-media:
	@./labctl clean-media
