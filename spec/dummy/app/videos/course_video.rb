# frozen_string_literal: true

class CourseVideo < ApplicationVideo
  rendition :full,   scale: 1.0
  rendition :medium, scale: 0.5
end
