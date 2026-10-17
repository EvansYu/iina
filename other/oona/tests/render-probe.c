// Offscreen integration probe for the pinned embedded renderer. Requires macOS.
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static void *get_proc(void *context, const char *name) {
  return dlsym(RTLD_DEFAULT, name);
}

static void check(int result) {
  if (result < 0) {
    fprintf(stderr, "ERROR: %s\n", mpv_error_string(result));
    exit(1);
  }
}

static double monotonic_time(void) {
  struct timespec time;
  clock_gettime(CLOCK_MONOTONIC, &time);
  return time.tv_sec + time.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "Usage: %s sample output.ppm [hwdec] [flip:0|1] [subtitle-file]\n", argv[0]);
    return 2;
  }
  CGLPixelFormatAttribute attributes[] = {
    kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
    kCGLPFAAccelerated, 0
  };
  CGLPixelFormatObj pixel_format;
  CGLContextObj gl;
  GLint count;
  if (CGLChoosePixelFormat(attributes, &pixel_format, &count) ||
      CGLCreateContext(pixel_format, NULL, &gl)) {
    fprintf(stderr, "Cannot create OpenGL context (run outside sandbox).\n");
    return 3;
  }
  CGLDestroyPixelFormat(pixel_format);
  CGLSetCurrentContext(gl);
  fprintf(stderr, "GL %s\n", glGetString(GL_VERSION));

  mpv_handle *mpv = mpv_create();
  if (!mpv) return 1;
  check(mpv_set_option_string(mpv, "config", "no"));
  check(mpv_set_option_string(mpv, "vo", "libmpv"));
  check(mpv_set_option_string(mpv, "ao", "null"));
  check(mpv_set_option_string(mpv, "hwdec", argc > 3 ? argv[3] : "no"));
  check(mpv_set_option_string(mpv, "start", "60"));
  check(mpv_set_option_string(mpv, "target-trc", "srgb"));
  check(mpv_set_option_string(mpv, "target-prim", "bt.709"));
  check(mpv_set_option_string(mpv, "sid", argc > 5 ? "auto" : "no"));
  if (argc > 5) check(mpv_set_option_string(mpv, "sub-files", argv[5]));
  check(mpv_request_log_messages(mpv, "v"));
  check(mpv_initialize(mpv));
  check(mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE));

  mpv_render_context *renderer = NULL;
  mpv_opengl_init_params gl_init = {.get_proc_address = get_proc};
  int advanced = 1;
  mpv_render_param init[] = {
    {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL_NEXT},
    {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
    {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced}, {0}
  };
  check(mpv_render_context_create(&renderer, mpv, init));

  GLuint texture, fbo;
  glGenTextures(1, &texture);
  glBindTexture(GL_TEXTURE_2D, texture);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 960, 540, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return 1;
  mpv_opengl_fbo target = {.fbo = fbo, .w = 960, .h = 540, .internal_format = GL_RGBA8};
  int flip = argc > 4 ? atoi(argv[4]) : 1;
  mpv_render_param render[] = {
    {MPV_RENDER_PARAM_OPENGL_FBO, &target}, {MPV_RENDER_PARAM_FLIP_Y, &flip}, {0}
  };
  const char *load[] = {"loadfile", argv[1], NULL};
  check(mpv_command(mpv, load));

  double begin = monotonic_time(), position = 0;
  int frames = 0, errors = 0;
  while (monotonic_time() - begin < 15) {
    mpv_event *event;
    while ((event = mpv_wait_event(mpv, 0))->event_id != MPV_EVENT_NONE) {
      if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
        mpv_event_log_message *message = event->data;
        fprintf(stderr, "[%s] %s", message->prefix, message->text);
        if (message->log_level <= MPV_LOG_LEVEL_ERROR) errors++;
      }
      if (event->event_id == MPV_EVENT_PROPERTY_CHANGE) {
        mpv_event_property *property = event->data;
        if (property->format == MPV_FORMAT_DOUBLE && property->data)
          position = *(double *)property->data;
      }
      if (event->event_id == MPV_EVENT_END_FILE) {
        mpv_event_end_file *end = event->data;
        check(end->error);
      }
    }
    if (mpv_render_context_update(renderer) & MPV_RENDER_UPDATE_FRAME) {
      check(mpv_render_context_render(renderer, render));
      mpv_render_context_report_swap(renderer);
      frames++;
    }
    if (position >= 62 && frames > 10) break;
    usleep(1000);
  }

  unsigned char *pixels = malloc(960 * 540 * 3);
  FILE *output = fopen(argv[2], "wb");
  if (!pixels || !output) return 1;
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, 960, 540, GL_RGB, GL_UNSIGNED_BYTE, pixels);
  fprintf(output, "P6\n960 540\n255\n");
  // Normalize the caller-requested framebuffer orientation for comparison.
  for (int y = 0; y < 540; y++) {
    int row = flip ? 539 - y : y;
    fwrite(pixels + row * 960 * 3, 1, 960 * 3, output);
  }
  fclose(output);
  free(pixels);

  char *decoder = mpv_get_property_string(mpv, "hwdec-current");
  char *matrix = mpv_get_property_string(mpv, "video-params/colormatrix");
  fprintf(stderr, "RESULT frames=%d pos=%f hw=%s csp=%s errors=%d\n",
          frames, position, decoder ? decoder : "?", matrix ? matrix : "?", errors);
  mpv_free(decoder);
  mpv_free(matrix);
  mpv_render_context_free(renderer);
  mpv_terminate_destroy(mpv);
  glDeleteFramebuffers(1, &fbo);
  glDeleteTextures(1, &texture);
  CGLSetCurrentContext(NULL);
  CGLDestroyContext(gl);
  return frames > 10 && position >= 62 && !errors ? 0 : 1;
}
