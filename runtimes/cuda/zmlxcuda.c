#include <dlfcn.h>
#include <string.h>
#include <stdio.h>

void *zmlxcuda_dlopen(const char *filename, int flags)
{
    if (filename != NULL)
    {
        fprintf(stderr,"hugo-- %s \n", filename);

        char *replacements[] = {
            // "libcudart.so", "libcudart.so.12", NULL, NULL,
            NULL, NULL,
        };
        for (int i = 0; replacements[i] != NULL; i += 2)
        {
            if (strcmp(filename, replacements[i]) == 0)
            {
                filename = replacements[i + 1];
                break;
            }
        }
    }
    return dlopen(filename, flags);
}
